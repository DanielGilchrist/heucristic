require "../document/store"
require "../document/text"
require "../syntax"
require "./uri"

module Heucristic
  module Server
    class OpenDocuments
      getter dirty : Set(String)

      def initialize : Nil
        @store = Document::Store.new
        @trees = Hash(String, Crystal::ASTNode).new
        @dirty = Set(String).new
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
        @dirty << path(document) if document.is_a?(Document::Open)
        document
      end

      def close(uri : String) : Nil
        @store.close(uri)
        @trees.delete(uri)
        @dirty.delete(path_of(uri))
      end

      def saved(uri : String) : Nil
        @dirty.delete(path_of(uri))
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
        document.text if document.is_a?(Document::Open)
      end

      def version(uri : String) : Int32?
        document = @store[uri]
        document.is_a?(Document::Open) ? document.version : nil
      end
    end
  end
end
