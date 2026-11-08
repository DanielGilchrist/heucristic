require "../document/span"
require "../syntax/type"
require "./evident"
require "./identity"

module Heucristic
  module Index
    record Constant,
      identity : Identity,
      path : String,
      name_span : Document::Span,
      value : String | ImplicitValue,
      type : Syntax::Type | Evident::NotEvident,
      expression : Crystal::ASTNode? do
      delegate name, to: identity

      record ImplicitValue
    end
  end
end
