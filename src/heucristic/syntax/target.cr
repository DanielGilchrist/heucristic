require "compiler/crystal/syntax"

module Heucristic
  module Syntax
    record OnDef, node : Crystal::Def
    record OnCall, node : Crystal::Call
    record OnPath, node : Crystal::Path, enclosing : Array(String)

    alias Target = OnDef | OnCall | OnPath
  end
end
