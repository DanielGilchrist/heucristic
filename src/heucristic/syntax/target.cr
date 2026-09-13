require "compiler/crystal/syntax"
require "./context"

module Heucristic
  module Syntax
    record OnDef, node : Crystal::Def, context : Context
    record OnCall, node : Crystal::Call, context : Context
    record OnPath, node : Crystal::Path, context : Context, segment : Int32
    record OnVar, name : String, location : Crystal::Location?, context : Context
    record OnInstanceVar, name : String, context : Context
    record OnName, name : String, location : Crystal::Location, context : Context
    record OnRequire, node : Crystal::Require

    alias Target = OnDef | OnCall | OnPath | OnVar | OnInstanceVar | OnName | OnRequire
  end
end
