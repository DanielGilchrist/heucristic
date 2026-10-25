require "compiler/crystal/syntax"

module Heucristic
  module Resolve
    module Terminator
      abstract def terminates?(call : Crystal::Call, path : Array(Crystal::ASTNode)) : Bool
    end
  end
end
