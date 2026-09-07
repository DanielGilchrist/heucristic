module Heucristic
  module Document
    record Point, line : Int32, column : Int32 do
      include Comparable(Point)

      def self.from(location : Crystal::Location) : Point
        new(location.line_number, location.column_number)
      end

      def <=>(other : Point) : Int32
        {line, column} <=> {other.line, other.column}
      end

      def advance(columns : Int32) : Point
        Point.new(line, column + columns)
      end
    end
  end
end
