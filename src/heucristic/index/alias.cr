require "../document/span"
require "../syntax/type_reader"

module Heucristic
  module Index
    record Alias,
      name : String,
      target : Syntax::TypeReader::Outcome,
      path : String,
      name_span : Document::Span
  end
end
