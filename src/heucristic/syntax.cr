require "compiler/crystal/syntax"
require "./syntax/broken"

require "./syntax/variable_restorer"

module Heucristic
  module Syntax
    extend self

    def parse_fragment(
      source : String,
      path : String,
      at : Crystal::Location,
      variables : Set(String) = Set(String).new,
    ) : Crystal::ASTNode | Broken
      parser = Crystal::Parser.new(source, nil, [variables])
      parser.filename = path
      parser.wants_doc = true
      parser.line_number = at.line_number
      parser.column_number = at.column_number
      parsed = parser.parse
      variables.empty? ? parsed : parsed.transform(VariableRestorer.new(variables))
    rescue error : Crystal::SyntaxException
      Broken.new(
        error.message || "syntax error",
        Document::Point.new(error.line_number, error.column_number),
        error.size,
      )
    end

    def parse(source : String, path : String) : Crystal::ASTNode | Broken
      parser = Crystal::Parser.new(source)
      parser.filename = path
      parser.wants_doc = true
      parser.parse
    rescue error : Crystal::SyntaxException
      Broken.new(
        error.message || "syntax error",
        Document::Point.new(error.line_number, error.column_number),
        error.size,
      )
    end
  end
end
