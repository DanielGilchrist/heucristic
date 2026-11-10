require "compiler/crystal/syntax"

module Heucristic
  module Syntax
    module Interpolation
      def self.parts(node : Crystal::StringInterpolation) : Array(Crystal::ASTNode)
        node.expressions.reject(Crystal::StringLiteral)
      end
    end
  end
end
