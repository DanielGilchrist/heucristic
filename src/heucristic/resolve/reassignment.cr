require "compiler/crystal/syntax"

module Heucristic
  module Resolve
    record Reassignment, value : Crystal::ASTNode, path : Array(Crystal::ASTNode)
  end
end
