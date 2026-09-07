require "lsprotocol"
require "../version"
require "../log"
require "../protocol/message"
require "../protocol/encoder"
require "../document/store"
require "../syntax/parse"
require "../syntax/cursor"
require "../index/workspace"
require "../index/loader"
require "./uri"
require "./diagnostics"
require "./decoded_params"
require "./outcome"

module Heucristic
  module Server
    class Session
      INDEXED = "$/heucristic/indexed"

      getter root : String
      getter workspace : Index::Workspace

      def initialize(@notify : String ->) : Nil
        @root = Dir.current
        @documents = Document::Store.new
        @trees = Hash(String, Crystal::ASTNode).new
        @workspace = Index::Workspace.new
        @stopping = false
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
        [@root]
      end

      def indexed(files : Array(Index::File)) : Nil
        @workspace.replace_all(files)
        @documents.each { |document| index_document(document) }
        @notify.call(Protocol::Encoder.notification(INDEXED, {files: @workspace.size}))
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
          publish(document.uri, document.version, Diagnostics.none)
        end
      end

      private def index_document(document : Document::Open) : Nil
        tree = @trees[document.uri]?
        return unless tree

        path = Uri.to_path(document.uri)
        path = document.uri if path.is_a?(Uri::NotAFile)
        @workspace.update(Index::Collector.collect(path, document.text, tree))
      end

      private def hover(request : Protocol::Request) : Outcome
        params = DecodedParams.decode(request.params, LSProtocol::HoverParams)
        return invalid(request.id, params) if params.is_a?(DecodedParams::Invalid)

        target = target_at(params.text_document.uri.to_s, params.position)
        candidates = candidates_for(target)
        return reply(request.id, nil) if candidates.empty?

        sections = candidates.map do |candidate|
          "```crystal\n#{candidate.signature}\n```\n#{candidate.qualified}"
        end
        contents = LSProtocol::MarkupContent.new(
          kind: LSProtocol::MarkupKind::Markdown, value: sections.join("\n\n---\n\n")
        )
        reply(request.id, LSProtocol::Hover.new(contents: contents))
      end

      private def definition(request : Protocol::Request) : Outcome
        params = DecodedParams.decode(request.params, LSProtocol::DefinitionParams)
        return invalid(request.id, params) if params.is_a?(DecodedParams::Invalid)

        target = target_at(params.text_document.uri.to_s, params.position)
        return reply(request.id, nil) unless target.is_a?(Syntax::OnCall)

        locations = candidates_for(target).map do |candidate|
          LSProtocol::Location.new(
            range: candidate.name_span.to_range, uri: URI.parse(Uri.from_path(candidate.path))
          )
        end
        reply(request.id, locations.empty? ? nil : locations)
      end

      private def target_at(uri : String, position : LSProtocol::Position) : Syntax::Target?
        document = @documents[uri]
        return if document.is_a?(Document::Store::Missing)
        tree = @trees[uri]?
        return unless tree

        point = document.text.point(position)
        return if point.is_a?(Document::OutOfRange)

        Syntax::Cursor.find(tree, point)
      end

      private def candidates_for(target : Syntax::Target?) : Array(Index::Def)
        case target
        in Nil then Array(Index::Def).new
        in Syntax::OnDef
          signature = Index::Signature.of(target.node)
          @workspace.named(target.node.name).select { |candidate| candidate.signature == signature }
        in Syntax::OnCall
          call = target.node
          return Array(Index::Def).new if call.obj
          count = call.args.size
          @workspace.named(call.name).select(&.arity.accepts?(count))
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
        @notify.call(
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
