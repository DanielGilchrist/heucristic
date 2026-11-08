require "lsprotocol"
require "../version"
require "../log"
require "../index/synthesized"
require "../protocol/message"
require "../protocol/encoder"
require "../protocol/transport"
require "./open_documents"
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
require "./resolver_caches"
require "./macro_state"
require "./answerer"
require "./source_paths"
require "./references"
require "./parameter_hint"
require "./symbols"
require "./completion"
require "./rename"
require "../index/sites"
require "./compiler_state"
require "./notice"
require "./indexed_payload"
require "./published"
require "./immediacy"
require "../check/suite"
require "../check/settled"
require "../index/collector"
require "../index/macro_target"

module Heucristic
  module Server
    class Session
      CHECK_DELAY = 300.milliseconds
      NO_TARGET   = "no def, call, constant, variable or instance variable under the cursor"

      @root : String

      @workspace : Index::Workspace

      @semantic : String?

      @executable : String?

      getter progress : Progress

      def initialize(@transport : Protocol::Transport, events : Channel(Index::Event)) : Nil
        @root = Dir.current
        @semantic = nil
        @executable = nil
        @published = Published.new
        @check_generations = Hash(String, Int32).new
        @sweep = 0
        @workspace = Index::Workspace.new
        @documents = OpenDocuments.new(@workspace)
        @compiler = CompilerState.new(events, @transport, @documents)
        @shims = Index::Shims.new
        @types = Resolve::Types.new(@workspace)
        @methods = Resolve::Methods.new(@workspace, @types)
        @receiver = Resolve::Receiver.new(@workspace, @shims, @types, @methods)
        @caches = ResolverCaches.new(@types, @methods, @receiver)
        @macros = MacroState.new(events, @transport, @workspace, @shims, @methods, @caches)
        @references = References.new(@workspace, @types, @receiver)
        @hints = ParameterHint.new(@workspace, @types, @receiver, @references)
        @sources = SourcePaths.new
        @answerer = Answerer.new(@workspace, @types, @methods, @receiver, @hints, @macros, @sources)
        @symbols = Symbols.new(@workspace)
        @completion = Completion.new(@workspace, @types, @methods, @receiver)
        @rename = Rename.new
        @index_stdlib = true
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

        roots.concat(@sources.paths(@root))
      end

      def shim_roots : Array(String)
        ShimRoots.for(@root)
      end

      def indexed(event : Index::Finished) : Nil
        @shims.replace_all(event.shims)
        @workspace.replace_all(event.files)
        @workspace.replace_sites(event.sites)
        @macros.restore
        @caches.invalidate
        @documents.each { |document| index_document(document) }
        @transport.send(Protocol::Encoder.notification(
          Notice::Indexed.method,
          IndexedPayload.new(
            @workspace.size, @shims.size, event.elapsed.total_milliseconds.round
          ),
        ))
        @macros.indexed(@root, @semantic)
        @compiler.start(@root, @executable)
      end

      def macros_started(event : Index::MacrosStarted) : Nil
        @macros.started(event)
      end

      def macros_expanded(event : Index::MacrosExpanded) : Nil
        @macros.expanded(event, @root, @semantic, @documents.paths)
        sweep
        @macros.finished(@root, @semantic, event.target)
      end

      def macros_failed(event : Index::MacrosFailed) : Nil
        @macros.failed(event)
        sweep
        @macros.finished(@root, @semantic, event.target)
      end

      def macros_unavailable(event : Index::MacrosUnavailable) : Nil
        @macros.unavailable(event)
        sweep
        @macros.finished(@root, @semantic, event.target)
      end

      def compiler_started : Nil
        @compiler.started
      end

      def compiler_finished(event : Index::CompilerFinished) : Nil
        @compiler.finished(event, @root, @executable) do |batch|
          @published.compiler(batch).each do |uri|
            publish(uri, @documents.version(uri), @published.for(uri))
          end
        end
      end

      def compiler_failed(event : Index::CompilerFailed) : Nil
        @compiler.failed(event, @root, @executable)
      end

      def compiler_unavailable(event : Index::CompilerUnavailable) : Nil
        @compiler.unavailable(event, @root, @executable)
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
        @macros.opened(@documents.path(document), @root, @semantic)
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
        @check_generations.delete(uri)
        @published.forget(uri)
        publish(uri, nil, @published.for(uri))
      end

      private def analyse(document : Document::Open, immediacy : Immediacy) : Outcome
        path = @documents.path(document)
        tree = Syntax.parse(document.text.source, path)
        case tree
        in Syntax::Broken
          @published.syntax(document.uri, Diagnostics.for(tree, document.text))
        in Crystal::ASTNode
          @documents.parsed(document.uri, tree)
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

        changed = @published.checks(uri, check(@documents.path_of(uri)))
        publish(uri, document.version, @published.for(uri)) if changed
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
          @macros.done?,
          @documents.dirty_paths,
          @macros.compiled_files,
          @root,
          shim_roots,
          @documents.paths,
        )
        return Diagnostics.none if settled.uncompiled_file?(path)

        suite = Check::Suite.new(@workspace, @types, @methods, @receiver, settled, @root)
        suite.findings(sites).map { |finding| Diagnostics.warning(finding) }
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
            publish(uri, @documents.version(uri), @published.for(uri)) if changed
            Fiber.yield
          end
        end
      end

      private def index_document(document : Document::Open) : Nil
        tree = @documents.tree(document.uri)
        return unless tree

        path = @documents.path(document)
        changed = @workspace.update(Index::Collector.collect(path, document.text, tree))
        @workspace.update_sites(Index::Sites.of(path, document.text, tree))
        @receiver.forget(path)
        return unless changed

        @caches.invalidate
      end

      private def rename(request : Protocol::Request) : Outcome
        params = DecodedParams.decode(request.params, LSProtocol::RenameParams)
        return invalid(request.id, params) if params.is_a?(DecodedParams::Invalid)

        uri = params.text_document.uri.to_s
        document = @documents[uri]
        tree = @documents.tree(uri)
        return reply(request.id, nil) if document.is_a?(Document::Store::Missing) || tree.nil?

        point = document.text.point(params.position)
        return reply(request.id, nil) if point.is_a?(Document::OutOfRange)

        path = @documents.path(document)
        target = Syntax::Cursor.find(tree, point, path)
        return reply(request.id, nil) unless target

        answer = answer_at(uri, params.position)
        declared = answer.entries.reject { |entry| Index::MacroTarget.generated?(entry.path) }
        if declared.empty? && !answer.entries.empty?
          reason = "a macro-generated def cannot be renamed"
          return error(request.id, Protocol::Encoder::INVALID_REQUEST, reason)
        end

        locations = uses_of(target, Answer.of(declared), tree, uri, document.text)
        declared.each { |entry| @answerer.locate(entry).try { |location| locations << location } }
        return reply(request.id, nil) if locations.empty?

        edit = @rename.edits(
          locations.uniq,
          params.new_name,
          target.is_a?(Syntax::OnInstanceVar),
          answer.entries.any?(Index::Namespace) || target.is_a?(Syntax::OnPath),
        ) { |file| @documents.text(file) }
        if edit.is_a?(Rename::Invalid)
          return error(request.id, Protocol::Encoder::INVALID_REQUEST, edit.reason)
        end

        reply(request.id, edit)
      end

      private def completion(request : Protocol::Request) : Outcome
        params = DecodedParams.decode(request.params, LSProtocol::CompletionParams)
        return invalid(request.id, params) if params.is_a?(DecodedParams::Invalid)

        uri = params.text_document.uri.to_s
        document = @documents[uri]
        return reply(request.id, nil) if document.is_a?(Document::Store::Missing)

        offset = document.text.offset(params.position)
        return reply(request.id, nil) if offset.is_a?(Document::OutOfRange)

        path = @documents.path(document)
        request_at = Completion::Request.new(document.text, offset, path, @sources.paths(@root))
        items = @completion.complete(request_at)
        reply(request.id, LSProtocol::CompletionList.new(is_incomplete: false, items: items))
      end

      private def document_symbols(request : Protocol::Request) : Outcome
        params = DecodedParams.decode(request.params, LSProtocol::DocumentSymbolParams)
        return invalid(request.id, params) if params.is_a?(DecodedParams::Invalid)

        reply(request.id, @symbols.in_document(@documents.path_of(params.text_document.uri.to_s)))
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
        tree = @documents.tree(uri)
        return reply(request.id, nil) if document.is_a?(Document::Store::Missing) || tree.nil?

        point = document.text.point(params.position)
        return reply(request.id, nil) if point.is_a?(Document::OutOfRange)

        path = @documents.path(document)
        target = Syntax::Cursor.find(tree, point, path)
        return reply(request.id, nil) unless target

        answer = answer_at(uri, params.position)
        locations = uses_of(target, answer, tree, uri, document.text)
        if params.context.include_declaration
          answer.entries.each do |entry|
            @answerer.locate(entry).try { |location| locations << location }
          end
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
        if sections.empty? && answer.notes.empty?
          sections.concat(@answerer.describe_all(answer.entries, @root))
        end
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
          location = @answerer.locate(entry)
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
        tree = @documents.tree(uri)
        return Answer.note("the file has never parsed, fix the syntax error first") unless tree

        point = document.text.point(position)
        return Answer.note("position is outside the document") if point.is_a?(Document::OutOfRange)

        path = @documents.path(document)
        target = Syntax::Cursor.find(tree, point, path)
        unless target
          return Answer.note(NO_TARGET)
        end

        @answerer.answer(target, path, document.text, @root)
      end

      private def did_save(notification : Protocol::Notification) : Outcome
        params = DecodedParams.decode(notification.params, LSProtocol::DidSaveTextDocumentParams)
        return Silence.new if params.is_a?(DecodedParams::Invalid)

        @documents.saved(params.text_document.uri.to_s)
        @macros.saved(@root, @semantic)
        @compiler.start(@root, @executable)
        Silence.new
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
