require "compiler/crystal/syntax"

module Heucristic
  module Syntax
    module ParameterName
      def self.location(argument : Crystal::Arg, source : String) : Crystal::Location?
        start = argument.location
        external = argument.external_name
        return start if start.nil? || external == argument.name

        lines = source.lines
        row = start.line_number - 1
        column = after_external(lines[row]?, start.column_number - 1)
        return unless column

        row, column = after_whitespace(lines, row, column)
        return unless lines[row]?.try(&.[column..]?).try(&.starts_with?(argument.name))

        Crystal::Location.new(start.filename, row + 1, column + 1)
      end

      def self.after_external(line : String?, column : Int32) : Int32?
        return unless line

        rest = line[column..]?
        return unless rest

        if rest.starts_with?('"')
          closing = rest.index('"', 1)
          return unless closing

          return column + closing + 1
        end

        column + (rest.each_char.index { |char| !(char.alphanumeric? || char == '_') } || rest.size)
      end

      def self.after_whitespace(lines : Array(String), row : Int32, column : Int32) : {Int32, Int32}
        loop do
          line = lines[row]?
          return {row, column} unless line

          while column < line.size && line[column].whitespace?
            column += 1
          end
          return {row, column} if column < line.size || row + 1 >= lines.size

          row += 1
          column = 0
        end
      end
    end
  end
end
