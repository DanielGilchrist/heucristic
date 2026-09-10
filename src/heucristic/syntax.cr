require "compiler/crystal/syntax"
require "./syntax/broken"

module Heucristic
  module Syntax
    extend self

    def parse_fragment(
      source : String,
      path : String,
      at : Crystal::Location,
    ) : Crystal::ASTNode | Broken
      parser = Crystal::Parser.new(source)
      parser.filename = path
      parser.wants_doc = true
      parser.line_number = at.line_number
      parser.column_number = at.column_number
      parser.parse
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
