require "compiler/crystal/syntax"

module Heucristic
  module Syntax
    record OnDef, node : Crystal::Def
    record OnCall, node : Crystal::Call

    alias Target = OnDef | OnCall
  end
end
