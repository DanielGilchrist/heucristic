require "../document/span"
require "../syntax/type_reader"
require "./identity"

module Heucristic
  module Index
    record Alias,
      identity : Identity,
      target : Syntax::TypeReader::Outcome,
      path : String,
      name_span : Document::Span do
      delegate name, to: identity
    end
  end
end
