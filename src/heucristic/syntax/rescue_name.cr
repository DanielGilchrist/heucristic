require "compiler/crystal/syntax"

module Heucristic
  module Syntax
    module RescueName
      KEYWORD = /\Arescue\s+/

      def self.location(clause : Crystal::Rescue, lines : Array(String)) : Crystal::Location?
        start = clause.location
        return unless start && clause.name

        tail = lines[start.line_number - 1]?.try(&.[(start.column_number - 1)..]?)
        keyword = tail.try(&.match(KEYWORD))
        return unless keyword

        column = start.column_number + keyword[0].size
        Crystal::Location.new(start.filename, start.line_number, column)
      end
    end
  end
end
