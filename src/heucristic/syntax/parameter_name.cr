require "compiler/crystal/syntax"

module Heucristic
  module Syntax
    module ParameterName
      def self.location(argument : Crystal::Arg) : Crystal::Location?
        start = argument.location
        external = argument.external_name
        return start if start.nil? || external == argument.name

        column = start.column_number + external.size + 1
        Crystal::Location.new(start.filename, start.line_number, column)
      end
    end
  end
end
