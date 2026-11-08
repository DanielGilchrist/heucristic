require "../document/store"
require "../document/text"
require "../index/workspace"
require "../syntax"
require "./uri"

module Heucristic
  module Server
    class OpenDocuments
      @dirty_snapshot : Set(String)?

      def initialize(@workspace : Index::Workspace) : Nil
        @store = Document::Store.new
        @trees = Hash(String, Crystal::ASTNode).new
        @dirty = Set(String).new
        @dirty_snapshot = nil
      end

      def open(uri : String, version : Int32, source : String) : Document::Open
        @store.open(uri, version, source)
      end

      def change(
        uri : String,
        version : Int32,
        changes : Array(LSProtocol::TextDocumentContentChangeEvent),
      ) : Document::Open | Document::Store::Missing | Document::OutOfRange
        document = @store.change(uri, version, changes)
        if document.is_a?(Document::Open)
          @dirty << path(document)
          @dirty_snapshot = nil
        end
        document
      end

      def close(uri : String) : Nil
        @store.close(uri)
        @trees.delete(uri)
        mark_clean(uri)
      end

      def saved(uri : String) : Nil
        mark_clean(uri)
      end

      def dirty_paths : Set(String)
        @dirty_snapshot ||= @dirty.dup
      end

      def [](uri : String) : Document::Open | Document::Store::Missing
        @store[uri]
      end

      def each(& : Document::Open ->) : Nil
        @store.each { |document| yield document }
      end

      def tree(uri : String) : Crystal::ASTNode?
        @trees[uri]?
      end

      def parsed(uri : String, tree : Crystal::ASTNode) : Nil
        @trees[uri] = tree
      end

      def path(document : Document::Open) : String
        path_of(document.uri)
      end

      def path_of(uri : String) : String
        path = Uri.to_path(uri)
        path.is_a?(Uri::NotAFile) ? uri : path
      end

      def paths : Set(String)
        paths = Set(String).new
        each { |document| paths << path(document) }
        paths
      end

      def text(path : String) : Document::Text?
        document = @store[Uri.from_path(path)]
        return document.text if document.is_a?(Document::Open)

        @workspace.sites(path).try(&.text)
      end

      def version(uri : String) : Int32?
        document = @store[uri]
        document.is_a?(Document::Open) ? document.version : nil
      end

      private def mark_clean(uri : String) : Nil
        @dirty.delete(path_of(uri))
        @dirty_snapshot = nil
      end
    end
  end
end
