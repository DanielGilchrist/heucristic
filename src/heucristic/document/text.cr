require "lsprotocol"
require "./point"
require "./span"
require "./out_of_range"

module Heucristic
  module Document
    struct Text
      getter source : String

      @line_starts : Array(Int32)

      def self.line_starts(source : String) : Array(Int32)
        starts = [0]
        source.each_byte.with_index do |byte, offset|
          starts << offset + 1 if byte === '\n'
        end
        starts
      end

      def initialize(@source : String) : Nil
        @line_starts = Text.line_starts(@source)
      end

      def offset(position : LSProtocol::Position) : Int32 | OutOfRange
        line = position.line.to_i32
        return OutOfRange.new(position.line) if line >= @line_starts.size

        start = @line_starts[line]
        stop = line_end(line)
        units = 0_u32
        offset = start

        line_slice(start, stop).each_char do |char|
          break if units >= position.character
          units += utf16_units(char)
          offset += char.bytesize
        end

        offset
      end

      def point(position : LSProtocol::Position) : Point | OutOfRange
        offset = offset(position)
        return offset if offset.is_a?(OutOfRange)

        line = position.line.to_i32
        column = line_slice(@line_starts[line], offset).size
        Point.new(line + 1, column + 1)
      end

      def point_at(offset : Int32) : Point | OutOfRange
        return OutOfRange.new(0_u32) if offset < 0 || offset > @source.bytesize

        line = @line_starts.rindex { |start| start <= offset } || 0
        column = line_slice(@line_starts[line], offset).size
        Point.new(line + 1, column + 1)
      end

      def position(point : Point) : LSProtocol::Position | OutOfRange
        line = point.line - 1
        return OutOfRange.new(line.to_u32) if line < 0 || line >= @line_starts.size

        start = @line_starts[line]
        stop = line_end(line)
        units = 0_u32
        remaining = point.column - 1

        line_slice(start, stop).each_char do |char|
          break if remaining <= 0
          units += utf16_units(char)
          remaining -= 1
        end

        LSProtocol::Position.new(line: line.to_u32, character: units)
      end

      def span(from : Point, to : Point) : Span | OutOfRange
        start = position(from)
        return start if start.is_a?(OutOfRange)
        stop = position(to)
        return stop if stop.is_a?(OutOfRange)

        Span.new(start.line, start.character, stop.line, stop.character)
      end

      def span_at(location : Crystal::Location, size : Int32) : Span?
        start = Point.from(location)
        found = span(start, start.advance(size))
        found.is_a?(Span) ? found : nil
      end

      def span_of(word : String, after : Crystal::Location, skipping : Int32) : Span?
        line = after.line_number - 1
        start = @line_starts[line]?
        return unless start

        tail = line_slice(start, line_end(line))[(after.column_number - 1 + skipping)..]?
        return unless tail

        word_start = tail.lstrip(' ')
        return unless word_start.starts_with?(word)

        column = after.column_number + skipping + tail.size - word_start.size
        from = Point.new(line + 1, column)
        found = span(from, from.advance(word.size))
        found.is_a?(Span) ? found : nil
      end

      def splice(from : Int32, to : Int32, replacement : String) : Text
        Text.new(String.build(@source.bytesize + replacement.bytesize) do |io|
          io.write(@source.to_slice[0, from])
          io << replacement
          io.write(@source.to_slice[to, @source.bytesize - to])
        end)
      end

      private def line_end(line : Int32) : Int32
        next_line = line + 1
        return @source.bytesize if next_line >= @line_starts.size

        stop = @line_starts[next_line] - 1
        stop -= 1 if stop > @line_starts[line] && @source.to_slice[stop - 1] === '\r'
        stop
      end

      private def line_slice(start : Int32, stop : Int32) : String
        @source.byte_slice(start, stop - start)
      end

      private def utf16_units(char : Char) : UInt32
        char.ord > 0xFFFF ? 2_u32 : 1_u32
      end
    end
  end
end
