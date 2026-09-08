require "lsprotocol"
require "../version"
require "../log"
require "../protocol/message"
require "../protocol/encoder"
require "../protocol/transport"
require "../document/store"
require "../syntax/parse"
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
require "../crystal_env"
require "../resolve/local_declarations"

module Heucristic
  module Server
    class Session
      INDEXED = "$/heucristic/indexed"

      getter root : String
      getter workspace : Index::Workspace
      getter progress : Progress

      def initialize(@transport : Protocol::Transport) : Nil
        @root = Dir.current
        @documents = Document::Store.new
        @trees = Hash(String, Crystal::ASTNode).new
        @workspace = Index::Workspace.new
        @shims = Index::Shims.new
        @types = Resolve::Types.new(@workspace)
        @methods = Resolve::Methods.new(@workspace, @types)
        @receiver = Resolve::Receiver.new(@workspace, @shims, @types, @methods)
        @stopping = false
        @index_stdlib = true
        @progress = Progress.new(@transport, false)
      end

      def handle(request : Protocol::Request) : Outcome
        case request.method
        when LSProtocol::INITIALIZE               then initialize_session(request)
        when LSProtocol::SHUTDOWN                 then reply(request.id, nil)
        when LSProtocol::TEXT_DOCUMENT_HOVER      then hover(request)
        when LSProtocol::TEXT_DOCUMENT_DEFINITION then definition(request)
        else
          error(
            request.id, Protocol::Encoder::METHOD_NOT_FOUND, "unsupported method #{request.method}"
          )
        end
      end

      def handle(notification : Protocol::Notification) : Outcome
        case notification.method
        when LSProtocol::EXIT                     then Stop.new
        when LSProtocol::TEXT_DOCUMENT_DID_OPEN   then did_open(notification)
        when LSProtocol::TEXT_DOCUMENT_DID_CHANGE then did_change(notification)
        when LSProtocol::TEXT_DOCUMENT_DID_CLOSE  then did_close(notification)
        else
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
        @types.invalidate
        @documents.each { |document| index_document(document) }
        @transport.send(Protocol::Encoder.notification(
          INDEXED,
          {
            files:      @workspace.size,
            shims:      @shims.size,
            elapsed_ms: event.elapsed.total_milliseconds.round,
          },
        ))
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
        supported = params.capabilities.window.try(&.work_done_progress) || false
        @progress = Progress.new(@transport, supported)

        reply(request.id, LSProtocol::InitializeResult.new(
          capabilities: LSProtocol::ServerCapabilities.new(
            text_document_sync: LSProtocol::TextDocumentSyncOptions.new(
              open_close: true,
              change: LSProtocol::TextDocumentSyncKind::Incremental,
            ),
            hover_provider: true,
            definition_provider: true,
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
        analyse(document)
      end

      private def did_change(notification : Protocol::Notification) : Outcome
        params = DecodedParams.decode(notification.params, LSProtocol::DidChangeTextDocumentParams)
        return Silence.new if params.is_a?(DecodedParams::Invalid)

        document = @documents.change(
          params.text_document.uri.to_s, params.text_document.version, params.content_changes
        )
        case document
        in Document::Open           then analyse(document)
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
        publish(uri, nil, Diagnostics.none)
      end

      private def analyse(document : Document::Open) : Outcome
        path = Uri.to_path(document.uri)
        path = document.uri if path.is_a?(Uri::NotAFile)

        tree = Syntax.parse(document.text.source, path)
        case tree
        in Syntax::Broken
          publish(document.uri, document.version, Diagnostics.for(tree, document.text))
        in Crystal::ASTNode
          @trees[document.uri] = tree
          @workspace.update(Index::Collector.collect(path, document.text, tree))
          @types.invalidate
          publish(document.uri, document.version, Diagnostics.none)
        end
      end

      private def index_document(document : Document::Open) : Nil
        tree = @trees[document.uri]?
        return unless tree

        path = Uri.to_path(document.uri)
        path = document.uri if path.is_a?(Uri::NotAFile)
        @workspace.update(Index::Collector.collect(path, document.text, tree))
        @types.invalidate
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
        locations = answer.entries.map do |entry|
          LSProtocol::Location.new(
            range: entry.name_span.to_range, uri: URI.parse(Uri.from_path(entry.path))
          )
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

        case (target = Syntax::Cursor.find(tree, point))
        in Nil
          Answer.note("no def, call, constant, variable or instance variable under the cursor")
        in Syntax::OnDef         then answer_def(target)
        in Syntax::OnCall        then answer_call(target)
        in Syntax::OnPath        then answer_path(target)
        in Syntax::OnVar         then answer_var(target, document.text)
        in Syntax::OnInstanceVar then answer_instance_var(target)
        end
      end

      private def answer_def(target : Syntax::OnDef) : Answer
        signature = Index::Signature.of(target.node)
        entries = Array(Index::Entry).new
        @workspace.named(target.node.name).each do |candidate|
          entries << candidate if candidate.signature == signature
        end
        if entries.empty?
          return Answer.note("this def is not indexed yet, the file may have a syntax error")
        end

        Answer.of(entries)
      end

      private def answer_call(target : Syntax::OnCall) : Answer
        call = target.node
        receiver = @receiver.of_call(call, target.context)
        if receiver.is_a?(Resolve::Unknown)
          unless receiver.reason.top_level?
            return Answer.note("receiver of `#{call.name}`: #{receiver}")
          end

          entries = Array(Index::Entry).new
          @workspace.named(call.name).each do |candidate|
            entries << candidate if candidate.arity.accepts?(call.args.size)
          end
          return Answer.of(entries)
        end

        shape = @receiver.shape_of(call, target.context)
        found = @methods.lookup(receiver, shape)
        return Answer.note("no `#{call.name}` indexed on #{receiver}") if found.empty?

        site = Resolve::Receiver::Site.new(call.block, target.context, Array(Resolve::Binding).new)
        sections = found.map { |entry| describe_resolved(entry, receiver, shape.arguments, site) }
        entries = Array(Index::Entry).new(found.size)
        found.each { |entry| entries << entry }
        Answer.new(entries, Array(Document::Span).new, sections, Array(String).new)
      end

      private def answer_path(target : Syntax::OnPath) : Answer
        node = target.node
        scope = Resolve::Scope.new(target.context.owner, target.context.type_vars)
        names = node.names[0, target.segment + 1]
        located = @types.locate_any(Syntax::Named.new(names, node.global?), scope)
        return Answer.note(located.to_s) if located.is_a?(Resolve::Unknown)

        entries = Array(Index::Entry).new
        @workspace.namespaces(located).each { |entry| entries << entry }
        @workspace.aliases(located).each { |entry| entries << entry }
        @workspace.constants(located).each { |entry| entries << entry }
        Answer.of(entries)
      end

      private def answer_var(target : Syntax::OnVar, text : Document::Text) : Answer
        note = typed(@receiver.variable(target.name, target.context))
        spans = Array(Document::Span).new
        if (definition = target.context.def_node)
          if (parameter = definition.args.find(&.name.==(target.name)))
            add_span(spans, text, parameter.location, target.name.size)
          elsif (declaration = Resolve::LocalDeclarations.find(definition.body, target.name))
            add_span(spans, text, declaration.var.location, target.name.size)
          end
        end
        Answer.new(Array(Index::Entry).new, spans, [note], Array(String).new)
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
        case (returning = @receiver.return_type(entry, receiver, arguments, site))
        in Resolve::Resolved then fence("# #{entry.qualified}", signature)
        in Resolve::Unknown  then fence("# #{entry.qualified}", signature, "# returns #{returning}")
        end
      end

      private def describe(entry : Index::Entry) : String
        case entry
        in Index::Def
          fence("# #{entry.qualified}", entry.signature)
        in Index::Namespace
          fence(namespace_header(entry))
        in Index::Alias
          fence("alias #{entry.name} = #{entry.target}")
        in Index::InstanceVar
          fence("# #{entry.owner}", "#{entry.name} : #{entry.type}")
        in Index::Constant
          type = entry.type
          typed = type.is_a?(Syntax::Type) ? " # : #{type.to_s.lchop("::")}" : ""
          owner = entry.name.rpartition("::")[0]
          short = entry.name.rpartition("::")[2]
          lines = owner.empty? ? Array(String).new : ["# #{owner}"]
          value = entry.value
          lines << (value.is_a?(String) ? "#{short} = #{value}#{typed}" : "#{short}#{typed}")
          fence(lines)
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
          Protocol::Encoder.notification(LSProtocol::TEXT_DOCUMENT_PUBLISH_DIAGNOSTICS, params)
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
