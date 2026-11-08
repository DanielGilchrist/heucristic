require "lsprotocol"
require "../version"
require "../log"
require "../requires"
require "../index/macro_call"
require "../index/synthesized"
require "../protocol/message"
require "../protocol/encoder"
require "../protocol/transport"
require "../document/store"
require "../syntax"
require "../syntax/cursor"
require "../index/workspace"
require "../index/entry"
require "../index/shims"
require "./shim_roots"
require "../resolve/types"
require "../resolve/receiver"
require "../resolve/methods"
require "../index/loader"
require "./uri"
require "./diagnostics"
require "./decoded_params"
require "./outcome"
require "./answer"
require "./progress"
require "./options"
require "./macros"
require "./references"
require "./parameter_hint"
require "./symbols"
require "./completion"
require "./rename"
require "../index/sites"
require "./macro_status"
require "./compiler"
require "./compiler_status"
require "./notice"
require "./stage"
require "./published"
require "./immediacy"
require "../check/suite"
require "../check/settled"
require "../index/collector"
require "../index/macro_site"
require "../index/macro_target"
require "../index/generated"
require "../crystal_env"
require "../resolve/local_declarations"

module Heucristic
  module Server
    class Session
      CHECK_DELAY = 300.milliseconds
      MAIN        = Index::MacroTarget::Main.wire

      @root : String

      @workspace : Index::Workspace

      getter progress : Progress

      def initialize(@transport : Protocol::Transport, events : Channel(Index::Event)) : Nil
        @root = Dir.current
        @macros = Macros.new(events)
        @macro_status = MacrosPending.new.as(MacroStatus)
        @macro_sites = Hash(String, Hash(Int32, Index::MacroSite)).new
        @generated = Hash(Index::MacroTarget, Index::File).new
        @compiled = Hash(Index::MacroTarget, Set(String)).new
        @spec_wanted = false
        @loose = Set(String).new
        @indexed = false
        @semantic = nil.as(String?)
        @compiler = Compiler.new(events)
        @compiler_status = CompilerPending.new.as(CompilerStatus)
        @executable = nil.as(String?)
        @published = Published.new
        @dirty = Set(String).new
        @check_generations = Hash(String, Int32).new
        @sweep = 0
        @documents = Document::Store.new
        @trees = Hash(String, Crystal::ASTNode).new
        @workspace = Index::Workspace.new
        @shims = Index::Shims.new
        @types = Resolve::Types.new(@workspace)
        @methods = Resolve::Methods.new(@workspace, @types)
        @receiver = Resolve::Receiver.new(@workspace, @shims, @types, @methods)
        @references = References.new(@workspace, @types, @receiver)
        @hints = ParameterHint.new(@workspace, @types, @receiver, @references)
        @symbols = Symbols.new(@workspace)
        @completion = Completion.new(@workspace, @types, @methods, @receiver)
        @rename = Rename.new
        @index_stdlib = true
        @source_paths = nil
        @progress = Progress.new(@transport, false)
      end

      def handle(request : Protocol::Request) : Outcome
        method = Protocol::Method.from_wire(request.method)
        unless method
          return error(
            request.id, Protocol::Encoder::METHOD_NOT_FOUND, "unsupported method #{request.method}"
          )
        end

        case method
        in .initialize?       then initialize_session(request)
        in .shutdown?         then reply(request.id, nil)
        in .hover?            then hover(request)
        in .definition?       then definition(request)
        in .references?       then references(request)
        in .document_symbol?  then document_symbols(request)
        in .completion?       then completion(request)
        in .rename?           then rename(request)
        in .workspace_symbol? then workspace_symbols(request)
        in .initialized?, .exit?, .did_open?, .did_change?, .did_close?, .did_save?,
           .publish_diagnostics?, .progress?, .work_done_progress_create?
          error(
            request.id,
            Protocol::Encoder::INVALID_REQUEST,
            "#{request.method} is not a request",
          )
        end
      end

      def handle(notification : Protocol::Notification) : Outcome
        method = Protocol::Method.from_wire(notification.method)
        return Silence.new unless method

        case method
        in .exit?        then Stop.new
        in .did_open?    then did_open(notification)
        in .did_change?  then did_change(notification)
        in .did_close?   then did_close(notification)
        in .did_save?    then did_save(notification)
        in .initialized? then Silence.new
        in .initialize?, .shutdown?, .hover?, .definition?, .references?, .document_symbol?,
           .completion?, .rename?, .workspace_symbol?, .publish_diagnostics?, .progress?,
           .work_done_progress_create?
          Log.info("#{notification.method} arrived as a notification and was ignored")
          Silence.new
        end
      end

      def handle(response : Protocol::Response) : Outcome
        Silence.new
      end

      def index_roots : Array(String)
        roots = [@root]
        return roots unless @index_stdlib

        roots.concat(source_paths)
      end

      def source_paths : Array(String)
        @source_paths ||= case (paths = CrystalEnv.source_paths(@root))
                          in CrystalEnv::Unavailable
                            Log.info("crystal source paths unavailable: #{paths.reason}")
                            Array(String).new
                          in Array(String)
                            paths
                          end
      end

      def shim_roots : Array(String)
        ShimRoots.for(@root)
      end

      def indexed(event : Index::Finished) : Nil
        @shims.replace_all(event.shims)
        @workspace.replace_all(event.files)
        @workspace.replace_sites(event.sites)
        @generated.each_value { |file| @workspace.update(file) }
        @types.invalidate
        @methods.invalidate
        @receiver.invalidate
        @indexed = true
        @documents.each { |document| index_document(document) }
        @transport.send(Protocol::Encoder.notification(
          Notice::Indexed.method,
          {
            files:      @workspace.size,
            shims:      @shims.size,
            elapsed_ms: event.elapsed.total_milliseconds.round,
          },
        ))
        @macros.start(@root, @semantic, :main)
        @macros.start(@root, @semantic, :spec) if @spec_wanted
        @compiler.start(@root, @executable)
      end

      def macros_started(event : Index::MacrosStarted) : Nil
        case event.target
        in .main?
          @macro_status = MacrosPending.new
          notify_macros
        in .spec?, .loose?
          notify_target_macros(event.target, Stage::Pending, nil, 0)
        end
      end

      def macros_expanded(event : Index::MacrosExpanded) : Nil
        path = event.target.generated_path
        tree = Syntax.parse(event.source, path)
        if tree.is_a?(Syntax::Broken)
          macros_broken(event.target, "generated source does not parse: #{tree.message}")
        else
          text = Document::Text.new(event.source)
          collected = Index::Collector.collect(path, text, tree)
          file = Index::Generated.merge(collected, event.sites, @workspace, @shims,
            Index::LoadedFiles.new(event.files.to_set, shim_roots))
          @generated[event.target] = file
          @workspace.update(file)
          @workspace.expand(event.target, event.expansions)
          @types.invalidate
          @methods.invalidate
          @receiver.invalidate
          sites = @macro_sites[path] = Hash(Int32, Index::MacroSite).new
          event.sites.each { |site| sites[site.line] = site }
          @compiled[event.target] = event.files.to_set
          @methods.compiled(Resolve::Compiled.new(@compiled, shim_roots))
          elapsed = event.elapsed.total_milliseconds.round
          case event.target
          in .main?
            @macro_status = MacrosDone.new(file.defs.size, elapsed, event.excluded)
            notify_macros
          in .spec?, .loose?
            note = exclusion_note(event.excluded)
            notify_target_macros(event.target, Stage::Done, note, file.defs.size)
          end
          @documents.each { |document| want_loose_macros(document_path(document)) }
        end
        sweep
        @macros.finished(@root, @semantic, event.target)
      end

      def macros_failed(event : Index::MacrosFailed) : Nil
        macros_broken(event.target, event.reason)
        sweep
        @macros.finished(@root, @semantic, event.target)
      end

      def macros_unavailable(event : Index::MacrosUnavailable) : Nil
        case event.target
        in .main?
          @macro_status = MacrosOff.new(event.reason)
          notify_macros
        in .spec?, .loose?
          notify_target_macros(event.target, Stage::Unavailable, event.reason, 0)
        end
        sweep
        @macros.finished(@root, @semantic, event.target)
      end

      def compiler_started : Nil
        @compiler_status = CompilerPending.new
        notify_compiler
      end

      def compiler_finished(event : Index::CompilerFinished) : Nil
        frame = placed_frame(event.errors)
        batch = compiler_batch(frame)
        @published.compiler(batch).each { |uri| publish(uri, version_of(uri), @published.for(uri)) }
        @compiler_status = CompilerDone.new(
          batch.size,
          event.elapsed.total_milliseconds.round,
          frame.try { |found| File.expand_path(found.file, @root) },
          frame.try(&.line),
          frame.try(&.message),
        )
        notify_compiler
        @compiler.finished(@root, @executable)
      end

      def compiler_failed(event : Index::CompilerFailed) : Nil
        @compiler_status = CompilerBroken.new(event.reason)
        notify_compiler
        @compiler.finished(@root, @executable)
      end

      def compiler_unavailable(event : Index::CompilerUnavailable) : Nil
        @compiler_status = CompilerOff.new(event.reason)
        notify_compiler
        @compiler.finished(@root, @executable)
      end

      private def initialize_session(request : Protocol::Request) : Outcome
        params = DecodedParams.decode(request.params, LSProtocol::InitializeParams)
        return invalid(request.id, params) if params.is_a?(DecodedParams::Invalid)

        if (root_uri = params.root_uri)
          path = Uri.to_path(root_uri.to_s)
          @root = path if path.is_a?(String)
        elsif (root_path = params.root_path)
          @root = root_path
        end
        @index_stdlib = Options.stdlib?(params.initialization_options)
        @semantic = Options.semantic(params.initialization_options)
        @executable = Options.compiler(params.initialization_options)
        defines = Options.defines(params.initialization_options)
        @macros.defines(defines)
        @compiler.defines(defines)
        supported = params.capabilities.window.try(&.work_done_progress) || false
        @progress = Progress.new(@transport, supported)

        reply(request.id, LSProtocol::InitializeResult.new(
          capabilities: LSProtocol::ServerCapabilities.new(
            text_document_sync: LSProtocol::TextDocumentSyncOptions.new(
              open_close: true,
              change: LSProtocol::TextDocumentSyncKind::Incremental,
              save: true,
            ),
            hover_provider: true,
            definition_provider: true,
            references_provider: true,
            document_symbol_provider: true,
            completion_provider: LSProtocol::CompletionOptions.new(trigger_characters: [".", ":"]),
            rename_provider: true,
            workspace_symbol_provider: true,
          ),
          server_info: LSProtocol::ServerInfo.new(name: "heucristic", version: VERSION),
        ))
      end

      private def did_open(notification : Protocol::Notification) : Outcome
        params = DecodedParams.decode(notification.params, LSProtocol::DidOpenTextDocumentParams)
        return Silence.new if params.is_a?(DecodedParams::Invalid)

        text_document = params.text_document
        document = @documents.open(
          text_document.uri.to_s, text_document.version, text_document.text
        )
        want_spec_macros(document_path(document))
        want_loose_macros(document_path(document))
        analyse(document, Immediacy::Now)
      end

      private def want_loose_macros(path : String) : Nil
        return unless @compiled.has_key?(Index::MacroTarget::Main)
        return unless project_file?(path)
        return if path.starts_with?(File.join(@root, "spec") + "/")
        return if compiled_files.includes?(path) || @loose.includes?(path)

        @loose << path
        @macros.loose(@loose.to_a)
        @macros.start(@root, @semantic, :loose)
      end

      private def want_spec_macros(path : String) : Nil
        return if @spec_wanted || !path.starts_with?(File.join(@root, "spec") + "/")

        @spec_wanted = true
        @macros.start(@root, @semantic, :spec) if @indexed
      end

      private def did_change(notification : Protocol::Notification) : Outcome
        params = DecodedParams.decode(notification.params, LSProtocol::DidChangeTextDocumentParams)
        return Silence.new if params.is_a?(DecodedParams::Invalid)

        document = @documents.change(
          params.text_document.uri.to_s, params.text_document.version, params.content_changes
        )
        case document
        in Document::Open
          @dirty << document_path(document)
          analyse(document, Immediacy::AfterPause)
        in Document::Store::Missing then Silence.new
        in Document::OutOfRange
          Log.info("edit out of range at line #{document.line} in #{params.text_document.uri}")
          Silence.new
        end
      end

      private def did_close(notification : Protocol::Notification) : Outcome
        params = DecodedParams.decode(notification.params, LSProtocol::DidCloseTextDocumentParams)
        return Silence.new if params.is_a?(DecodedParams::Invalid)

        uri = params.text_document.uri.to_s
        @documents.close(uri)
        @trees.delete(uri)
        @dirty.delete(path_of(uri))
        @check_generations.delete(uri)
        @published.forget(uri)
        publish(uri, nil, @published.for(uri))
      end

      private def analyse(document : Document::Open, immediacy : Immediacy) : Outcome
        path = document_path(document)
        tree = Syntax.parse(document.text.source, path)
        case tree
        in Syntax::Broken
          @published.syntax(document.uri, Diagnostics.for(tree, document.text))
        in Crystal::ASTNode
          @trees[document.uri] = tree
          index_document(document)
          @published.syntax(document.uri, Diagnostics.none)
          case immediacy
          in .now?         then @published.checks(document.uri, check(path))
          in .after_pause? then schedule_check(document.uri)
          end
        end
        publish(document.uri, document.version, @published.for(document.uri))
      end

      private def schedule_check(uri : String) : Nil
        generation = (@check_generations[uri] ||= 0) + 1
        @check_generations[uri] = generation
        Fibers.detach(:check) do
          sleep CHECK_DELAY
          check_after_pause(uri, generation)
        end
      end

      private def check_after_pause(uri : String, generation : Int32) : Nil
        return unless @check_generations[uri]? == generation
        document = @documents[uri]
        return unless document.is_a?(Document::Open)

        changed = @published.checks(uri, check(path_of(uri)))
        publish(uri, document.version, @published.for(uri)) if changed
      end

      private def document_path(document : Document::Open) : String
        path_of(document.uri)
      end

      private def path_of(uri : String) : String
        path = Uri.to_path(uri)
        path.is_a?(Uri::NotAFile) ? uri : path
      end

      private def check(path : String) : Array(LSProtocol::Diagnostic)
        sites = @workspace.sites(path)
        return Diagnostics.none unless sites
        return Diagnostics.none if path.starts_with?(File.join(@root, "lib") + "/")
        return Diagnostics.none if shimmed?(path)

        settled = Check::Settled.new(
          @workspace,
          @types,
          @methods.descendants,
          @macro_status.is_a?(MacrosDone),
          @dirty,
          compiled_files,
          @root,
          shim_roots,
          open_paths,
        )
        return Diagnostics.none if settled.uncompiled_file?(path)

        suite = Check::Suite.new(@workspace, @types, @methods, @receiver, settled, @root)
        suite.findings(sites).map { |finding| Diagnostics.warning(finding) }
      end

      private def open_paths : Set(String)
        paths = Set(String).new
        @documents.each { |document| paths << document_path(document) }
        paths
      end

      private def shimmed?(path : String) : Bool
        shim_roots.any? { |shim_root| path.starts_with?("#{shim_root}/") }
      end

      private def sweep : Nil
        @sweep += 1
        generation = @sweep
        paths = Array(String).new
        @workspace.each_sites { |sites| paths << sites.path }
        Fibers.detach(:sweep) do
          paths.each do |path|
            break unless generation == @sweep

            uri = Uri.from_path(path)
            changed = @published.checks(uri, check(path))
            publish(uri, version_of(uri), @published.for(uri)) if changed
            Fiber.yield
          end
        end
      end

      private def index_document(document : Document::Open) : Nil
        tree = @trees[document.uri]?
        return unless tree

        path = document_path(document)
        changed = @workspace.update(Index::Collector.collect(path, document.text, tree))
        @workspace.update_sites(Index::Sites.of(path, document.text, tree))
        @receiver.forget(path)
        return unless changed

        @types.invalidate
        @methods.invalidate
        @receiver.invalidate
      end

      private def rename(request : Protocol::Request) : Outcome
        params = DecodedParams.decode(request.params, LSProtocol::RenameParams)
        return invalid(request.id, params) if params.is_a?(DecodedParams::Invalid)

        uri = params.text_document.uri.to_s
        document = @documents[uri]
        tree = @trees[uri]?
        return reply(request.id, nil) if document.is_a?(Document::Store::Missing) || tree.nil?

        point = document.text.point(params.position)
        return reply(request.id, nil) if point.is_a?(Document::OutOfRange)

        path = document_path(document)
        target = Syntax::Cursor.find(tree, point, path)
        return reply(request.id, nil) unless target

        answer = answer_at(uri, params.position)
        declared = answer.entries.reject { |entry| Index::MacroTarget.generated?(entry.path) }
        if declared.empty? && !answer.entries.empty?
          reason = "a macro-generated def cannot be renamed"
          return error(request.id, Protocol::Encoder::INVALID_REQUEST, reason)
        end

        locations = uses_of(target, Answer.of(declared), tree, uri, document.text)
        declared.each { |entry| locate(entry).try { |location| locations << location } }
        return reply(request.id, nil) if locations.empty?

        edit = @rename.edits(
          locations.uniq,
          params.new_name,
          target.is_a?(Syntax::OnInstanceVar),
          answer.entries.any?(Index::Namespace) || target.is_a?(Syntax::OnPath),
        ) { |file| text_for(file) }
        if edit.is_a?(Rename::Invalid)
          return error(request.id, Protocol::Encoder::INVALID_REQUEST, edit.reason)
        end

        reply(request.id, edit)
      end

      private def text_for(path : String) : Document::Text?
        open = @documents[Uri.from_path(path)]
        return open.text unless open.is_a?(Document::Store::Missing)

        @workspace.sites(path).try(&.text)
      end

      private def completion(request : Protocol::Request) : Outcome
        params = DecodedParams.decode(request.params, LSProtocol::CompletionParams)
        return invalid(request.id, params) if params.is_a?(DecodedParams::Invalid)

        uri = params.text_document.uri.to_s
        document = @documents[uri]
        return reply(request.id, nil) if document.is_a?(Document::Store::Missing)

        offset = document.text.offset(params.position)
        return reply(request.id, nil) if offset.is_a?(Document::OutOfRange)

        path = document_path(document)
        request_at = Completion::Request.new(document.text, offset, path, source_paths)
        items = @completion.complete(request_at)
        reply(request.id, LSProtocol::CompletionList.new(is_incomplete: false, items: items))
      end

      private def document_symbols(request : Protocol::Request) : Outcome
        params = DecodedParams.decode(request.params, LSProtocol::DocumentSymbolParams)
        return invalid(request.id, params) if params.is_a?(DecodedParams::Invalid)

        reply(request.id, @symbols.in_document(path_of(params.text_document.uri.to_s)))
      end

      private def workspace_symbols(request : Protocol::Request) : Outcome
        params = DecodedParams.decode(request.params, LSProtocol::WorkspaceSymbolParams)
        return invalid(request.id, params) if params.is_a?(DecodedParams::Invalid)

        reply(request.id, @symbols.matching(params.query, @root))
      end

      private def references(request : Protocol::Request) : Outcome
        params = DecodedParams.decode(request.params, LSProtocol::ReferenceParams)
        return invalid(request.id, params) if params.is_a?(DecodedParams::Invalid)

        uri = params.text_document.uri.to_s
        document = @documents[uri]
        tree = @trees[uri]?
        return reply(request.id, nil) if document.is_a?(Document::Store::Missing) || tree.nil?

        point = document.text.point(params.position)
        return reply(request.id, nil) if point.is_a?(Document::OutOfRange)

        path = document_path(document)
        target = Syntax::Cursor.find(tree, point, path)
        return reply(request.id, nil) unless target

        answer = answer_at(uri, params.position)
        locations = uses_of(target, answer, tree, uri, document.text)
        if params.context.include_declaration
          answer.entries.each { |entry| locate(entry).try { |location| locations << location } }
        end
        reply(request.id, locations.empty? ? nil : locations.uniq)
      end

      private def uses_of(
        target : Syntax::Target,
        answer : Answer,
        tree : Crystal::ASTNode,
        uri : String,
        text : Document::Text,
      ) : Array(LSProtocol::Location)
        case target
        in Syntax::OnDef, Syntax::OnCall, Syntax::OnPath, Syntax::OnName
          @references.of_entries(answer.entries)
        in Syntax::OnVar
          unless answer.entries.empty?
            return @references.of_entries(answer.entries)
          end

          @references.of_variable(target.name, target.context, tree, uri, text)
        in Syntax::OnInstanceVar
          owner = target.context.owner
          return Array(LSProtocol::Location).new unless owner.is_a?(String)

          @references.of_instance_var(target.name, owner)
        in Syntax::OnRequire
          Array(LSProtocol::Location).new
        end
      end

      private def hover(request : Protocol::Request) : Outcome
        params = DecodedParams.decode(request.params, LSProtocol::HoverParams)
        return invalid(request.id, params) if params.is_a?(DecodedParams::Invalid)

        answer = answer_at(params.text_document.uri.to_s, params.position)
        sections = answer.descriptions.dup
        sections.concat(describe_all(answer.entries)) if sections.empty? && answer.notes.empty?
        sections.concat(answer.notes)
        sections << "nothing indexed for this position" if sections.empty?

        contents = LSProtocol::MarkupContent.new(
          kind: LSProtocol::MarkupKind::Markdown, value: sections.join("\n\n---\n\n")
        )
        reply(request.id, LSProtocol::Hover.new(contents: contents))
      end

      private def definition(request : Protocol::Request) : Outcome
        params = DecodedParams.decode(request.params, LSProtocol::DefinitionParams)
        return invalid(request.id, params) if params.is_a?(DecodedParams::Invalid)

        uri = params.text_document.uri.to_s
        answer = answer_at(uri, params.position)
        locations = Array(LSProtocol::Location).new(answer.entries.size)
        answer.entries.each do |entry|
          location = locate(entry)
          locations << location if location
        end
        answer.spans.each do |span|
          locations << LSProtocol::Location.new(range: span.to_range, uri: URI.parse(uri))
        end
        answer.macros.each do |definition|
          uri_of = URI.parse(Uri.from_path(definition.path))
          locations << LSProtocol::Location.new(range: definition.name_span.to_range, uri: uri_of)
        end
        answer.files.each do |file|
          origin = LSProtocol::Position.new(line: 0, character: 0)
          range = LSProtocol::Range.new(start: origin, end: origin)
          locations << LSProtocol::Location.new(range: range, uri: URI.parse(Uri.from_path(file)))
        end
        reply(request.id, locations.empty? ? nil : locations)
      end

      private def answer_at(uri : String, position : LSProtocol::Position) : Answer
        document = @documents[uri]
        return Answer.note("document is not open") if document.is_a?(Document::Store::Missing)
        tree = @trees[uri]?
        return Answer.note("the file has never parsed, fix the syntax error first") unless tree

        point = document.text.point(position)
        return Answer.note("position is outside the document") if point.is_a?(Document::OutOfRange)

        path = document_path(document)
        case (target = Syntax::Cursor.find(tree, point, path))
        in Nil
          Answer.note("no def, call, constant, variable or instance variable under the cursor")
        in Syntax::OnDef  then answer_def(target)
        in Syntax::OnCall then answer_call(target)
        in Syntax::OnPath then answer_path(target)
        in Syntax::OnVar
          anchored = anchored_at(path, target.location)
          anchored.empty? ? answer_var(target, document.text) : Answer.of(anchored)
        in Syntax::OnInstanceVar then answer_instance_var(target)
        in Syntax::OnName
          anchored = anchored_at(path, target.location)
          return Answer.of(anchored) unless anchored.empty?

          Answer.note("nothing is declared by `#{target.name}` here")
        in Syntax::OnRequire then answer_require(target, path)
        end
      end

      private def answer_require(target : Syntax::OnRequire, path : String) : Answer
        string = target.node.string
        case (resolved = Requires.new(source_paths).resolve(string, path))
        in Requires::Unresolved
          tried = resolved.tried.join('\n') { |candidate| "- `#{candidate}`" }
          Answer.note("no file matches `require \"#{string}\"`, tried:\n#{tried}")
        in Array(String)
          return Answer.note("`require \"#{string}\"` matches no `.cr` files") if resolved.empty?

          Answer.files(resolved, "```\n#{resolved.join('\n')}\n```")
        end
      end

      private def anchored_at(path : String, location : Crystal::Location?) : Array(Index::Entry)
        entries = Array(Index::Entry).new
        file = @workspace.file(path)
        return entries unless file && location

        start = Document::Point.from(location)
        each_entry(file) do |entry|
          span = entry.name_span
          if span.start_line == start.line - 1 && span.start_character == start.column - 1
            entries << entry
          end
        end
        entries
      end

      private def each_entry(file : Index::File, & : Index::Entry ->) : Nil
        file.defs.each { |entry| yield entry }
        file.namespaces.each { |entry| yield entry }
        file.constants.each { |entry| yield entry }
        file.aliases.each { |entry| yield entry }
        file.instance_vars.each { |entry| yield entry }
      end

      private def answer_def(target : Syntax::OnDef) : Answer
        path = target.context.path
        entries = path ? @workspace.defs_at(path, target.node) : Array(Index::Def).new
        entries = generated_defs(target) if entries.empty?
        if entries.empty?
          return Answer.note("this def is not indexed yet, the file may have a syntax error")
        end

        Answer.of(Array(Index::Entry).new(entries.size).concat(entries))
      end

      private def generated_defs(target : Syntax::OnDef) : Array(Index::Def)
        node = target.node
        @workspace.named(node.name).select do |entry|
          Index::MacroTarget.generated?(entry.path) &&
            entry.owner == target.context.owner &&
            entry.receiver.metaclass? == !node.receiver.nil?
        end
      end

      private def answer_call(target : Syntax::OnCall) : Answer
        call = target.node
        enclosing = target.context.ancestors[0...-1]
        macro_call = Index::MacroCall.enclosing(enclosing, @workspace)
        if macro_call && call.obj.nil? && statement_of?(macro_call, enclosing)
          owner = "the `#{macro_call.name}` macro#{defined_at(macro_call)}"
          return Answer.note("`#{call.name}` is syntax of #{owner}, not a method call")
        end
        macros = Index::MacroCall.like?(call, @workspace) ? @workspace.macros(call.name) : nil
        if macros && !macros.empty? && !@receiver.macro_precedence(call, target.context).def?
          return Answer.macros(macros, macros.map { |definition| describe_macro(definition) })
        end

        receiver = @receiver.of_call(call, target.context)
        if receiver.is_a?(Resolve::Unknown)
          return Answer.note("receiver of `#{call.name}`: #{receiver}")
        end

        shape = @receiver.shape_of(call, target.context)
        found = if call.obj.nil? && Syntax::WellKnown::Super.named?(call.name)
                  @receiver.super_targets(call, target.context)
                else
                  @receiver.implementations(receiver, shape)
                end
        if found.empty?
          inherited = @methods.class_macros(receiver, shape)
          unless inherited.empty?
            described = inherited.map { |definition| describe_macro(definition) }
            return Answer.macros(inherited, described)
          end
        end
        if found.empty? && (action = @receiver.select_action(call, target.context))
          shape = @receiver.shape_of(action, target.context)
          found = @methods.lookup(receiver, shape)
        end
        if found.empty?
          forwarded = @receiver.forwarded_receiver(receiver)
          if forwarded.is_a?(Resolve::Resolved)
            receiver = forwarded
            found = @receiver.implementations(receiver, shape)
          end
        end
        if found.empty?
          return Answer.note("no `#{call.name}` indexed on #{receiver}#{macro_hint}")
        end

        site = Resolve::Receiver::Site.new(
          call.block, target.context, Array(Resolve::Binding).new, Array(String).new
        )
        sections = found.map { |entry| describe_resolved(entry, receiver, shape.arguments, site) }
        entries = Array(Index::Entry).new(found.size)
        found.each { |entry| entries << entry }
        Answer.new(entries, Array(Document::Span).new, sections, Array(String).new)
      end

      private def statement_of?(
        macro_call : Crystal::Call,
        ancestors : Array(Crystal::ASTNode),
      ) : Bool
        from = ancestors.index(&.same?(macro_call))
        return false unless from

        ancestors[(from + 1)..].all? do |node|
          node.is_a?(Crystal::Block) || node.is_a?(Crystal::Expressions)
        end
      end

      private def defined_at(macro_call : Crystal::Call) : String
        places = @workspace.macros(macro_call.name).map do |definition|
          "#{definition.path.sub(@root + "/", "")}:#{definition.name_span.start_line + 1}"
        end
        places.empty? ? "" : " at #{places.join(" and ")}"
      end

      private def describe_macro(definition : Index::MacroDef) : String
        owner = definition.owner
        parameters = definition.parameters.join(", ")
        String.build do |io|
          io << "```crystal\n"
          io << "# " << owner << '\n' if owner.is_a?(String)
          io << "macro " << definition.name << '(' << parameters << ")\n```"
        end
      end

      private def answer_path(target : Syntax::OnPath) : Answer
        node = target.node
        context = target.context
        scope = Resolve::Scope.of(context)
        names = node.names[0, target.segment + 1]
        located = @types.locate_any(Syntax::Named.new(names, node.global?), scope)
        return Answer.note(located.to_s) if located.is_a?(Resolve::Unknown)

        entries = Array(Index::Entry).new
        @workspace.namespaces(located).each { |entry| entries << entry if visible?(entry, context) }
        @workspace.aliases(located).each { |entry| entries << entry if visible?(entry, context) }
        @workspace.constants(located).each { |entry| entries << entry if visible?(entry, context) }
        Answer.of(entries)
      end

      private def visible?(
        entry : Index::Namespace | Index::Alias | Index::Constant,
        context : Syntax::Context,
      ) : Bool
        private_path = entry.private_path
        private_path.nil? || private_path == context.path
      end

      private def answer_var(target : Syntax::OnVar, text : Document::Text) : Answer
        resolution = @receiver.variable(target.name, target.context)
        notes = [typed(resolution)]
        if resolution.is_a?(Resolve::Unknown)
          @hints.for(target.name, target.context, @root).try { |hint| notes << hint }
        end
        spans = Array(Document::Span).new
        add_span(spans, text, introduced_at(target), target.name.size)
        Answer.new(Array(Index::Entry).new, spans, notes, Array(String).new)
      end

      private def introduced_at(target : Syntax::OnVar) : Crystal::Location?
        name = target.name
        target.context.blocks.reverse_each do |call|
          argument = call.block.try(&.args.find(&.name.==(name)))
          return argument.location if argument
        end

        definition = target.context.def_node
        body = definition ? definition.body : target.context.ancestors.first?
        return unless body
        if definition && (parameter = definition.args.find(&.name.==(name)))
          return parameter.location
        end
        if definition && (block_arg = definition.block_arg) && block_arg.name == name
          return block_arg.location
        end
        if (declaration = Resolve::LocalDeclarations.find(body, name))
          return declaration.var.location
        end

        Resolve::LocalAssignments.first_target(body, name).try(&.location)
      end

      private def answer_instance_var(target : Syntax::OnInstanceVar) : Answer
        note = typed(@receiver.instance_var(target.name, target.context))
        entries = Array(Index::Entry).new
        if (owner = target.context.owner).is_a?(String)
          @workspace.instance_vars_of(owner).each do |declared|
            entries << declared if declared.name == target.name
          end
        end
        Answer.new(entries, Array(Document::Span).new, [note], Array(String).new)
      end

      private def typed(resolution : Resolve::Resolution) : String
        case resolution
        in Resolve::Resolved then fence(resolution.to_s)
        in Resolve::Unknown  then resolution.to_s
        end
      end

      private def did_save(notification : Protocol::Notification) : Outcome
        params = DecodedParams.decode(notification.params, LSProtocol::DidSaveTextDocumentParams)
        return Silence.new if params.is_a?(DecodedParams::Invalid)

        @dirty.delete(path_of(params.text_document.uri.to_s))
        @macros.start(@root, @semantic, :main)
        @macros.start(@root, @semantic, :spec) if @spec_wanted
        @macros.start(@root, @semantic, :loose) unless @loose.empty?
        @compiler.start(@root, @executable)
        Silence.new
      end

      private def notify_compiler : Nil
        payload = case (status = @compiler_status)
                  in CompilerPending
                    {
                      status:     Stage::Pending.wire,
                      errors:     0,
                      elapsed_ms: 0.0,
                      reason:     nil,
                      file:       nil,
                      line:       nil,
                      message:    nil,
                    }
                  in CompilerDone
                    {
                      status:     Stage::Done.wire,
                      errors:     status.errors,
                      elapsed_ms: status.elapsed_ms,
                      reason:     nil,
                      file:       status.file,
                      line:       status.line,
                      message:    status.message,
                    }
                  in CompilerBroken
                    {
                      status:     Stage::Failed.wire,
                      errors:     0,
                      elapsed_ms: 0.0,
                      reason:     status.reason,
                      file:       nil,
                      line:       nil,
                      message:    nil,
                    }
                  in CompilerOff
                    {
                      status:     Stage::Unavailable.wire,
                      errors:     0,
                      elapsed_ms: 0.0,
                      reason:     status.reason,
                      file:       nil,
                      line:       nil,
                      message:    nil,
                    }
                  end
        @transport.send(Protocol::Encoder.notification(Notice::Compiler.method, payload))
      end

      private def placed_frame(errors : Array(Check::CompilerError)) : Check::CompilerError?
        last = errors.last?
        return unless last

        failing = errors.select do |error|
          project_file?(error.file) && error.message == last.message
        end
        failing.first? || errors.reverse.find { |error| project_file?(error.file) } || last
      end

      private def compiler_batch(frame : Check::CompilerError?) : Published::Batch
        batch = Published::Batch.new
        return batch unless frame

        path = File.expand_path(frame.file, @root)
        uri = Uri.from_path(path)
        batch[uri] = [Diagnostics.compiler(frame, text_of(path))]
        batch
      end

      private def project_file?(file : String) : Bool
        path = File.expand_path(file, @root)
        path.starts_with?(@root + "/") && !path.starts_with?(File.join(@root, "lib") + "/")
      end

      private def text_of(path : String) : Document::Text?
        document = @documents[Uri.from_path(path)]
        return document.text if document.is_a?(Document::Open)

        @workspace.sites(path).try(&.text)
      end

      private def version_of(uri : String) : Int32?
        document = @documents[uri]
        document.is_a?(Document::Open) ? document.version : nil
      end

      private def notify_macros : Nil
        payload = case (status = @macro_status)
                  in MacrosPending
                    {
                      status:     Stage::Pending.wire,
                      defs:       0,
                      elapsed_ms: 0.0,
                      reason:     nil,
                      target:     MAIN,
                    }
                  in MacrosDone
                    {
                      status:     Stage::Done.wire,
                      defs:       status.defs,
                      elapsed_ms: status.elapsed_ms,
                      reason:     exclusion_note(status.excluded),
                      target:     MAIN,
                    }
                  in MacrosStale
                    {
                      status:     Stage::Stale.wire,
                      defs:       status.defs,
                      elapsed_ms: 0.0,
                      reason:     status.reason,
                      target:     MAIN,
                    }
                  in MacrosOff
                    {
                      status:     Stage::Unavailable.wire,
                      defs:       0,
                      elapsed_ms: 0.0,
                      reason:     status.reason,
                      target:     MAIN,
                    }
                  end
        @transport.send(Protocol::Encoder.notification(Notice::Macros.method, payload))
      end

      private def generated_defs : Int32
        @generated[Index::MacroTarget::Main]?.try(&.defs.size) || 0
      end

      private def compiled_files : Set(String)
        all = Set(String).new
        @compiled.each_value { |files| all.concat(files) }
        all
      end

      private def macros_broken(target : Index::MacroTarget, reason : String) : Nil
        case target
        in .main?
          @macro_status = MacrosStale.new(reason, generated_defs)
          notify_macros
        in .spec?, .loose?
          defs = @generated[target]?.try(&.defs.size) || 0
          notify_target_macros(target, Stage::Stale, reason, defs)
        end
      end

      private def notify_target_macros(
        target : Index::MacroTarget,
        stage : Stage,
        reason : String?,
        defs : Int32,
      ) : Nil
        payload = {
          status:     stage.wire,
          defs:       defs,
          elapsed_ms: 0.0,
          reason:     reason,
          target:     target.wire,
        }
        @transport.send(Protocol::Encoder.notification(Notice::Macros.method, payload))
      end

      private def macro_hint : String
        case (status = @macro_status)
        in MacrosPending         then "; macros are still expanding"
        in MacrosStale           then "; macros could not be expanded (#{status.reason})"
        in MacrosOff, MacrosDone then ""
        end
      end

      private def exclusion_note(excluded : Hash(String, String)) : String?
        return if excluded.empty?

        parts = excluded.join(", ") do |path, reason|
          "#{path.sub(@root + "/", "")} (#{reason.lines.first? || reason})"
        end
        "left out of the expansion because it failed: #{parts}"
      end

      private def site_of(entry : Index::Entry) : Index::MacroSite?
        sites = @macro_sites[entry.path]?
        return unless sites

        sites[entry.name_span.start_line.to_i + 1]?
      end

      private def provenance(entry : Index::Entry) : String?
        site_of(entry).try { |site| "# #{site.provenance(@root)}" }
      end

      private def locate(entry : Index::Entry) : LSProtocol::Location?
        site = site_of(entry)
        unless site
          return if Index::MacroTarget.generated?(entry.path)

          return LSProtocol::Location.new(
            range: entry.name_span.to_range, uri: URI.parse(Uri.from_path(entry.path))
          )
        end

        path = site.expanded_path
        line = site.expanded_line
        column = site.expanded_column
        return unless path && line && column

        start = LSProtocol::Position.new(line: (line - 1).to_u32, character: (column - 1).to_u32)
        finish = LSProtocol::Position.new(
          line: (line - 1).to_u32, character: (column - 1 + site.name.size).to_u32
        )
        range = LSProtocol::Range.new(start: start, end: finish)
        LSProtocol::Location.new(range: range, uri: URI.parse(Uri.from_path(path)))
      end

      private def fence(*lines : String) : String
        fence(lines.to_a)
      end

      private def fence(lines : Array(String)) : String
        "```crystal\n#{lines.join('\n')}\n```"
      end

      private def add_span(
        spans : Array(Document::Span),
        text : Document::Text,
        location : Crystal::Location?,
        size : Int32,
      ) : Nil
        return unless location

        start = Document::Point.from(location)
        span = text.span(start, start.advance(size))
        spans << span if span.is_a?(Document::Span)
      end

      private def describe_all(entries : Array(Index::Entry)) : Array(String)
        namespaces = entries.select(Index::Namespace)
        return entries.map { |entry| describe(entry) } if namespaces.size < 2

        primary = namespaces.find(&.is_a?(Index::ClassNamespace)) || namespaces[0]
        primary = namespaces.select(Index::ClassNamespace).find(&.type_vars.empty?.!) || primary
        others = entries.reject(Index::Namespace).map { |entry| describe(entry) }
        others.unshift(fence(namespace_header(primary), "# reopened in #{namespaces.size} places"))
      end

      private def describe_resolved(
        entry : Index::Def,
        receiver : Resolve::Resolved,
        arguments : Array(Resolve::Resolution),
        site : Resolve::Receiver::Site,
      ) : String
        signature = @receiver.signature(entry, receiver, arguments, site)
        lines = ["# #{entry.qualified}"]
        provenance(entry).try { |line| lines << line }
        lines << signature
        returning = @receiver.return_type(entry, receiver, arguments, site)
        lines << "# returns #{returning}" if returning.is_a?(Resolve::Unknown)
        fence(lines)
      end

      private def describe(entry : Index::Entry) : String
        case entry
        in Index::Def
          lines = ["# #{entry.qualified}"]
          provenance(entry).try { |line| lines << line }
          lines << entry.signature
          fence(lines)
        in Index::Namespace
          fence(namespace_header(entry))
        in Index::Alias
          fence("alias #{entry.name} = #{entry.target}")
        in Index::InstanceVar
          fence("# #{entry.owner}", "#{entry.name} : #{entry.type}")
        in Index::Constant
          value = entry.value
          return fence(entry.name) unless value.is_a?(String)

          fence("#{entry.name} = #{value} # : #{@receiver.type_of(entry)}")
        end
      end

      private def namespace_header(entry : Index::Namespace) : String
        case entry
        in Index::ClassNamespace
          String.build do |io|
            io << "abstract " if entry.abstract_type
            io << entry.keyword << ' ' << entry.name
            io << '(' << entry.type_vars.join(", ") << ')' unless entry.type_vars.empty?
            superclass = entry.superclass
            io << " < " << superclass unless superclass.is_a?(Index::Unrestricted)
          end
        in Index::ModuleNamespace
          generics = entry.type_vars.empty? ? "" : "(#{entry.type_vars.join(", ")})"
          "#{entry.keyword} #{entry.name}#{generics}"
        in Index::EnumNamespace
          base = entry.base_type
          suffix = base.is_a?(Index::Unrestricted) ? "" : " : #{base}"
          "#{entry.keyword} #{entry.name}#{suffix}"
        in Index::LibNamespace, Index::AnnotationNamespace
          "#{entry.keyword} #{entry.name}"
        end
      end

      private def publish(
        uri : String,
        version : Int32?,
        diagnostics : Array(LSProtocol::Diagnostic),
      ) : Outcome
        params = LSProtocol::PublishDiagnosticsParams.new(
          diagnostics: diagnostics, uri: URI.parse(uri), version: version
        )
        @transport.send(
          Protocol::Encoder.notification(Protocol::Method::PublishDiagnostics, params)
        )
        Silence.new
      end

      private def reply(id : Protocol::Id, result : T) : Reply forall T
        Reply.new(Protocol::Encoder.result(id, result))
      end

      private def error(id : Protocol::Id, code : Int32, message : String) : Reply
        Reply.new(Protocol::Encoder.error(id, code, message))
      end

      private def invalid(id : Protocol::Id, failure : DecodedParams::Invalid) : Reply
        error(id, Protocol::Encoder::INVALID_PARAMS, failure.reason)
      end
    end
  end
end
