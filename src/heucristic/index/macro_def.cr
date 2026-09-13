require "../document/span"
require "./owner"
require "./parameter"
require "./arity"
require "./macro_effect"

module Heucristic
  module Index
    record MacroDef,
      name : String,
      owner : Owner,
      path : String,
      name_span : Document::Span,
      parameters : Array(Parameter),
      arity : Arity,
      effect : MacroEffect,
      splices_block : Bool
  end
end
