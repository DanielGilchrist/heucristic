require "../document/span"
require "./rule"

module Heucristic
  module Check
    record Finding, rule : Rule, message : String, span : Document::Span
  end
end
