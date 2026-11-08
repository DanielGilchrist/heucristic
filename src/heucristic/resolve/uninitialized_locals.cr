require "compiler/crystal/syntax"

module Heucristic
  module Resolve
    class UninitializedLocals < Crystal::Visitor
      getter found : Crystal::Var?

      def self.find(body : Crystal::ASTNode, name : String) : Crystal::Var?
        finder = new(name)
        body.accept(finder)
        finder.found
      end

      def initialize(@name : String) : Nil
      end

      def visit(node : Crystal::UninitializedVar) : Bool
        var = node.var
        @found = var if var.is_a?(Crystal::Var) && var.name == @name
        @found.nil?
      end

      def visit(node : Crystal::Def) : Bool
        false
      end

      def visit(node : Crystal::ASTNode) : Bool
        @found.nil?
      end
    end
  end
end
