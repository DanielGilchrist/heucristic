require "compiler/crystal/syntax"
require "./context"
require "./placement"

module Heucristic
  module Syntax
    record OnDef, node : Crystal::Def, context : Context
    record OnCall, node : Crystal::Call, context : Context
    record OnPath, node : Crystal::Path, context : Context, segment : Int32
    record OnVar, name : String, location : Crystal::Location?, context : Context
    record OnInstanceVar, name : String, context : Context
    record OnLiteral,
      node : Crystal::StringLiteral | Crystal::StringInterpolation | Crystal::CharLiteral |
             Crystal::BoolLiteral | Crystal::NilLiteral | Crystal::RegexLiteral |
             Crystal::ArrayLiteral | Crystal::HashLiteral | Crystal::TupleLiteral |
             Crystal::NamedTupleLiteral | Crystal::RangeLiteral | Crystal::ProcLiteral,
      context : Context
    record OnAutocast,
      node : Crystal::NumberLiteral | Crystal::SymbolLiteral,
      placement : Placement,
      context : Context
    record OnRequire, node : Crystal::Require

    alias Target = OnDef | OnCall | OnPath | OnVar | OnInstanceVar | OnLiteral | OnAutocast |
                   OnRequire
  end
end
