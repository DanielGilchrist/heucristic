require "./open"
require "./edit"

module Heucristic
  module Document
    class Store
      record Missing, uri : String

      def initialize : Nil
        @open = Hash(String, Open).new
      end

      def open(uri : String, version : Int32, source : String) : Open
        @open[uri] = Open.new(uri, version, Text.new(source))
      end

      def change(
        uri : String,
        version : Int32,
        changes : Array(LSProtocol::TextDocumentContentChangeEvent),
      ) : Open | Missing | OutOfRange
        current = self[uri]
        return current if current.is_a?(Missing)

        text = Edit.apply_all(current.text, changes)
        return text if text.is_a?(OutOfRange)

        @open[uri] = Open.new(uri, version, text)
      end

      def close(uri : String) : Nil
        @open.delete(uri)
      end

      def [](uri : String) : Open | Missing
        @open[uri]? || Missing.new(uri)
      end

      def each(& : Open ->) : Nil
        @open.each_value { |document| yield document }
      end
    end
  end
end
