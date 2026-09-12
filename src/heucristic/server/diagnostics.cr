require "lsprotocol"
require "../syntax/broken"
require "../document/text"
require "../check/compiler_error"

module Heucristic
  module Server
    module Diagnostics
      extend self

      SOURCE   = "heucristic"
      COMPILER = "crystal"

      def for(broken : Syntax::Broken, text : Document::Text) : Array(LSProtocol::Diagnostic)
        stop = broken.at.advance(broken.size || 1)
        span = text.span(broken.at, stop)
        range = span.is_a?(Document::Span) ? span.to_range : last_resort_range(broken.at.line)

        [LSProtocol::Diagnostic.new(
          message: broken.message,
          range: range,
          severity: LSProtocol::DiagnosticSeverity::Error,
          source: SOURCE,
        )]
      end

      def compiler(error : Check::CompilerError, text : Document::Text?) : LSProtocol::Diagnostic
        LSProtocol::Diagnostic.new(
          message: error.message,
          range: compiler_range(error, text),
          severity: LSProtocol::DiagnosticSeverity::Error,
          source: COMPILER,
        )
      end

      def none : Array(LSProtocol::Diagnostic)
        Array(LSProtocol::Diagnostic).new
      end

      private def compiler_range(
        error : Check::CompilerError,
        text : Document::Text?,
      ) : LSProtocol::Range
        line = error.line || 1
        start = Document::Point.new(line, error.column)
        return last_resort_range(line) unless text

        size = error.size.zero? ? identifier_size(text, start) : error.size
        span = text.span(start, start.advance(Math.max(size, 1)))
        span.is_a?(Document::Span) ? span.to_range : last_resort_range(line)
      end

      private def identifier_size(text : Document::Text, start : Document::Point) : Int32
        position = text.position(start)
        return 1 if position.is_a?(Document::OutOfRange)

        offset = text.offset(position)
        return 1 if offset.is_a?(Document::OutOfRange)

        rest = text.source.byte_slice(offset, text.source.bytesize - offset)
        rest.each_char.take_while { |char| identifier?(char) }.size
      end

      private def identifier?(char : Char) : Bool
        char.alphanumeric? || char == '_' || char == '?' || char == '!'
      end

      private def last_resort_range(line : Int32) : LSProtocol::Range
        zero_based = Math.max(line - 1, 0).to_u32
        Document::Span.new(zero_based, 0_u32, zero_based, 0_u32).to_range
      end
    end
  end
end
