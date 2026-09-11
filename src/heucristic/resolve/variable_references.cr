require "compiler/crystal/syntax"

module Heucristic
  module Resolve
    class VariableReferences < Crystal::Visitor
      getter? found : Bool

      def self.include?(node : Crystal::ASTNode, name : String) : Bool
        finder = new(name)
        node.accept(finder)
        finder.found?
      end

      def initialize(@name : String) : Nil
        @found = false
      end

      def visit(node : Crystal::Var) : Bool
        @found = true if node.name == @name
        !@found
      end

      def visit(node : Crystal::Def) : Bool
        false
      end

      def visit(node : Crystal::ASTNode) : Bool
        !@found
      end
    end
  end
end
