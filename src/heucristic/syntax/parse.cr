require "compiler/crystal/syntax"
require "./broken"

module Heucristic
  module Syntax
    extend self

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
