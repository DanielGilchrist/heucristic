require "../document/span"
require "./owner"

module Heucristic
  module Index
    record MacroDef, name : String, owner : Owner, path : String, name_span : Document::Span
  end
end
