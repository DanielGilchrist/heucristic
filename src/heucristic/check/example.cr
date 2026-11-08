require "compiler/crystal/syntax"

module Heucristic
  module Check
    record Located, path : String, line : Int32 do
      def to_s(io : IO) : Nil
        io << path << ':' << line
      end
    end

    record Unplaced, path : String do
      def to_s(io : IO) : Nil
        io << path << ':'
      end
    end

    alias Example = Located | Unplaced

    module Examples
      extend self

      def at(path : String, location : Crystal::Location?) : Example
        return Unplaced.new(path) unless location

        Located.new(path, location.line_number)
      end
    end
  end
end
