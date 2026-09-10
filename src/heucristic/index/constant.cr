require "../document/span"
require "../syntax/type"
require "./evident"

module Heucristic
  module Index
    record Constant,
      name : String,
      path : String,
      name_span : Document::Span,
      value : String | ImplicitValue,
      type : Syntax::Type | Evident::NotEvident,
      expression : Crystal::ASTNode?,
      private_path : String? = nil do
      record ImplicitValue
    end
  end
end
