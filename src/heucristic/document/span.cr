module Heucristic
  module Document
    record Span,
      start_line : UInt32,
      start_character : UInt32,
      end_line : UInt32,
      end_character : UInt32 do
      def before?(other : Span) : Bool
        {start_line, start_character} < {other.start_line, other.start_character}
      end

      def to_range : LSProtocol::Range
        LSProtocol::Range.new(
          start: LSProtocol::Position.new(line: start_line, character: start_character),
          end: LSProtocol::Position.new(line: end_line, character: end_character),
        )
      end
    end
  end
end
