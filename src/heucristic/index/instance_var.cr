require "compiler/crystal/syntax"
require "../document/span"
require "../syntax/type_reader"
require "./origin"

module Heucristic
  module Index
    record InstanceVar,
      name : String,
      owner : String,
      type : Syntax::TypeReader::Outcome,
      path : String,
      name_span : Document::Span,
      origin : Origin,
      expression : Crystal::ASTNode? = nil
  end
end
