require "lsprotocol"
require "../syntax/broken"
require "../document/text"

module Heucristic
  module Server
    module Diagnostics
      extend self

      SOURCE = "heucristic"

      def for(broken : Syntax::Broken, text : Document::Text) : Array(LSProtocol::Diagnostic)
        stop = broken.at.advance(broken.size || 1)
        span = text.span(broken.at, stop)
        range = span.is_a?(Document::Span) ? span.to_range : last_resort_range(broken)

        [LSProtocol::Diagnostic.new(
          message: broken.message,
          range: range,
          severity: LSProtocol::DiagnosticSeverity::Error,
          source: SOURCE,
        )]
      end

      def none : Array(LSProtocol::Diagnostic)
        Array(LSProtocol::Diagnostic).new
      end

      private def last_resort_range(broken : Syntax::Broken) : LSProtocol::Range
        line = Math.max(broken.at.line - 1, 0).to_u32
        Document::Span.new(line, 0_u32, line, 0_u32).to_range
      end
    end
  end
end
