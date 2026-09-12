require "lsprotocol"
require "../version"
require "../log"
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
require "../check/calls"
require "../check/cases"
require "../check/generics"
require "../check/controls"
require "../check/abstracts"
require "../check/settled"
require "../index/collector"
require "../index/macro_site"
require "../index/generated"
require "../crystal_env"
require "../resolve/local_declarations"

module Heucristic
  module Server
    class Session
      GENERATED_PATH = "<macros>"
      CHECK_DELAY    = 300.milliseconds

      getter root : String

      getter workspace : Index::Workspace

      getter progress : Progress

      def initialize(@transport : Protocol::Transport, events : Channel(Index::Event)) : Nil
        @root = Dir.current
        @macros = Macros.new(events)
        @macro_status = MacrosPending.new.as(MacroStatus)
        @macro_sites = Hash(Int32, Index::MacroSite).new
        @generated = nil.as(Index::File?)
        @semantic = nil.as(String?)
        @compiler = Compiler.new(events)
        @compiler_status = CompilerPending.new.as(CompilerStatus)
        @executable = nil.as(String?)
        @published = Published.new
        @dirty = Set(String).new
        @check_generations = Hash(String, Int32).new
        @compiled = Set(String).new
        @sweep = 0
        @documents = Document::Store.new
        @trees = Hash(String, Crystal::ASTNode).new
        @workspace = Index::Workspace.new
        @shims = Index::Shims.new
        @types = Resolve::Types.new(@workspace)
        @methods = Resolve::Methods.new(@workspace, @types)
        @receiver = Resolve::Receiver.new(@workspace, @shims, @types, @methods)
        @references = References.new(@workspace, @types, @methods, @receiver)
        @symbols = Symbols.new(@workspace)
        @completion = Completion.new(@workspace, @types, @methods, @receiver)
        @rename = Rename.new
        @stopping = false
        @index_stdlib = true
        @progress = Progress.new(@transport, false)
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

        case (paths = CrystalEnv.source_paths(@root))
        in CrystalEnv::Unavailable
          Log.info("stdlib not indexed: #{paths.reason}")
        in Array(String)
          roots.concat(paths)
        end
        roots
      end

      def shim_roots : Array(String)
        ShimRoots.for(@root)
      end

      def indexed(event : Index::Finished) : Nil
        @shims.replace_all(event.shims)
        @workspace.replace_all(event.files)
        @workspace.replace_sites(event.sites)
        @generated.try { |file| @workspace.update(file) }
        @types.invalidate
        @receiver.invalidate
        @documents.each { |document| index_document(document) }
        @transport.send(Protocol::Encoder.notification(
          Notice::Indexed.method,
          {
            files:      @workspace.size,
            shims:      @shims.size,
            elapsed_ms: event.elapsed.total_milliseconds.round,
          },
        ))
        @macros.start(@root, @semantic)
        @compiler.start(@root, @executable)
      end

      def macros_started : Nil
        @macro_status = MacrosPending.new
        notify_macros
      end

      def macros_expanded(event : Index::MacrosExpanded) : Nil
        tree = Syntax.parse(event.source, GENERATED_PATH)
        if tree.is_a?(Syntax::Broken)
          reason = "generated source does not parse: #{tree.message}"
          @macro_status = MacrosStale.new(reason, generated_defs)
        else
          text = Document::Text.new(event.source)
          collected = Index::Collector.collect(GENERATED_PATH, text, tree)
          file = Index::Generated.merge(collected, event.sites, @workspace, @shims)
          @generated = file
          @workspace.update(file)
          @types.invalidate
          @receiver.invalidate
          @macro_sites.clear
          event.sites.each { |site| @macro_sites[site.line] = site }
          @compiled = event.files.to_set
          @macro_status = MacrosDone.new(file.defs.size, event.elapsed.total_milliseconds.round)
        end
        notify_macros
        sweep
        @macros.finished(@root, @semantic)
      end

      def macros_failed(event : Index::MacrosFailed) : Nil
        @macro_status = MacrosStale.new(event.reason, generated_defs)
        notify_macros
        sweep
        @macros.finished(@root, @semantic)
      end

      def macros_unavailable(event : Index::MacrosUnavailable) : Nil
        @macro_status = MacrosOff.new(event.reason)
        notify_macros
        sweep
        @macros.finished(@root, @semantic)
      end

      def compiler_started : Nil
        @compiler_status = CompilerPending.new
        notify_compiler
      end

      def compiler_finished(event : Index::CompilerFinished) : Nil
        batch = compiler_batch(event.errors)
        @published.compiler(batch).each { |uri| publish(uri, version_of(uri), @published.for(uri)) }
        @compiler_status = CompilerDone.new(batch.size, event.elapsed.total_milliseconds.round)
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

      private def did_open(notification : Protocol::Notification) : Outcome
        params = DecodedParams.decode(notification.params, LSProtocol::DidOpenTextDocumentParams)
        return Silence.new if params.is_a?(DecodedParams::Invalid)

        text_document = params.text_document
        document = @documents.open(
          text_document.uri.to_s, text_document.version, text_document.text
        )
        analyse(document, Immediacy::Now)
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

        settled = Check::Settled.new(
          @workspace, @types, @macro_status.is_a?(MacrosDone), @dirty, @compiled, @root, shim_roots
        )
        calls = Check::Calls.new(@workspace, @types, @methods, @receiver, settled)
        findings = calls.run(sites).findings
        Check::Cases.new(@workspace, @types, @receiver, settled).run(sites, findings)
        Check::Abstracts.new(@workspace, @methods, settled).run(path, findings)
        Check::Generics.new(@workspace, @types, settled, @root).run(sites, findings)
        Check::Controls.new.run(sites, findings)
        findings.sort_by! { |finding| {finding.span.start_line, finding.span.start_character} }
        findings.map { |finding| Diagnostics.warning(finding) }
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

        path = Uri.to_path(document.uri)
        path = document.uri if path.is_a?(Uri::NotAFile)
        @workspace.update(Index::Collector.collect(path, document.text, tree))
        @workspace.update_sites(Index::Sites.of(path, document.text, tree))
        @types.invalidate
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

        path = Uri.to_path(document.uri)
        path = document.uri if path.is_a?(Uri::NotAFile)
        target = Syntax::Cursor.find(tree, point, path)
        return reply(request.id, nil) unless target

        answer = answer_at(uri, params.position)
        declared = answer.entries.reject { |entry| entry.path == GENERATED_PATH }
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

        path = Uri.to_path(document.uri)
        path = document.uri if path.is_a?(Uri::NotAFile)
        items = @completion.complete(Completion::Request.new(document.text, offset, path))
        reply(request.id, LSProtocol::CompletionList.new(is_incomplete: false, items: items))
      end

      private def document_symbols(request : Protocol::Request) : Outcome
        params = DecodedParams.decode(request.params, LSProtocol::DocumentSymbolParams)
        return invalid(request.id, params) if params.is_a?(DecodedParams::Invalid)

        path = Uri.to_path(params.text_document.uri.to_s)
        path = params.text_document.uri.to_s if path.is_a?(Uri::NotAFile)
        reply(request.id, @symbols.in_document(path))
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

        path = Uri.to_path(document.uri)
        path = document.uri if path.is_a?(Uri::NotAFile)
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
        reply(request.id, locations.empty? ? nil : locations)
      end

      private def answer_at(uri : String, position : LSProtocol::Position) : Answer
        document = @documents[uri]
        return Answer.note("document is not open") if document.is_a?(Document::Store::Missing)
        tree = @trees[uri]?
        return Answer.note("the file has never parsed, fix the syntax error first") unless tree

        point = document.text.point(position)
        return Answer.note("position is outside the document") if point.is_a?(Document::OutOfRange)

        path = Uri.to_path(document.uri)
        path = document.uri if path.is_a?(Uri::NotAFile)
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
        signature = Index::Signature.of(target.node)
        owner = target.context.owner
        entries = Array(Index::Entry).new
        @workspace.named(target.node.name).each do |candidate|
          next unless candidate.signature == signature
          next unless candidate.owner == owner || candidate.owner == def_owner(target)

          entries << candidate
        end
        if entries.empty?
          return Answer.note("this def is not indexed yet, the file may have a syntax error")
        end

        Answer.of(entries)
      end

      private def def_owner(target : Syntax::OnDef) : Index::Owner
        receiver = target.node.receiver
        owner = target.context.owner
        return owner unless receiver.is_a?(Crystal::Path) && owner.is_a?(String)

        "#{owner}::#{receiver}"
      end

      private def answer_call(target : Syntax::OnCall) : Answer
        call = target.node
        receiver = @receiver.of_call(call, target.context)
        if receiver.is_a?(Resolve::Unknown)
          return Answer.note("receiver of `#{call.name}`: #{receiver}")
        end

        shape = @receiver.shape_of(call, target.context)
        found = @methods.lookup(receiver, shape)
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

      private def answer_path(target : Syntax::OnPath) : Answer
        node = target.node
        context = target.context
        scope = Resolve::Scope.new(
          context.owner, context.type_vars, Array(Resolve::Binding).new, context.path
        )
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
        note = typed(@receiver.variable(target.name, target.context))
        spans = Array(Document::Span).new
        add_span(spans, text, introduced_at(target), target.name.size)
        Answer.new(Array(Index::Entry).new, spans, [note], Array(String).new)
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
        @macros.start(@root, @semantic)
        @compiler.start(@root, @executable)
        Silence.new
      end

      private def notify_compiler : Nil
        payload = case (status = @compiler_status)
                  in CompilerPending
                    {status: Stage::Pending.wire, errors: 0, elapsed_ms: 0.0, reason: nil}
                  in CompilerDone
                    {
                      status:     Stage::Done.wire,
                      errors:     status.errors,
                      elapsed_ms: status.elapsed_ms,
                      reason:     nil,
                    }
                  in CompilerBroken
                    {status: Stage::Failed.wire, errors: 0, elapsed_ms: 0.0, reason: status.reason}
                  in CompilerOff
                    {
                      status:     Stage::Unavailable.wire,
                      errors:     0,
                      elapsed_ms: 0.0,
                      reason:     status.reason,
                    }
                  end
        @transport.send(Protocol::Encoder.notification(Notice::Compiler.method, payload))
      end

      private def compiler_batch(errors : Array(Check::CompilerError)) : Published::Batch
        batch = Published::Batch.new
        frame = errors.reverse.find { |error| project_file?(error.file) } || errors.first?
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
                    {status: Stage::Pending.wire, defs: 0, elapsed_ms: 0.0, reason: nil}
                  in MacrosDone
                    {
                      status:     Stage::Done.wire,
                      defs:       status.defs,
                      elapsed_ms: status.elapsed_ms,
                      reason:     nil,
                    }
                  in MacrosStale
                    {
                      status:     Stage::Stale.wire,
                      defs:       status.defs,
                      elapsed_ms: 0.0,
                      reason:     status.reason,
                    }
                  in MacrosOff
                    {
                      status:     Stage::Unavailable.wire,
                      defs:       0,
                      elapsed_ms: 0.0,
                      reason:     status.reason,
                    }
                  end
        @transport.send(Protocol::Encoder.notification(Notice::Macros.method, payload))
      end

      private def generated_defs : Int32
        @generated.try(&.defs.size) || 0
      end

      private def macro_hint : String
        case (status = @macro_status)
        in MacrosPending         then "; macros are still expanding"
        in MacrosStale           then "; macros could not be expanded (#{status.reason})"
        in MacrosDone, MacrosOff then ""
        end
      end

      private def site_of(entry : Index::Entry) : Index::MacroSite?
        return unless entry.path == GENERATED_PATH

        @macro_sites[entry.name_span.start_line.to_i + 1]?
      end

      private def provenance(entry : Index::Entry) : String?
        site_of(entry).try { |site| "# #{site.provenance(@root)}" }
      end

      private def locate(entry : Index::Entry) : LSProtocol::Location?
        site = site_of(entry)
        unless site
          return if entry.path == GENERATED_PATH

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
