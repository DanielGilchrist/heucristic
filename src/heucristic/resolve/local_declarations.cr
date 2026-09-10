require "compiler/crystal/syntax"

module Heucristic
  module Resolve
    class LocalDeclarations < Crystal::Visitor
      getter found : Crystal::TypeDeclaration?

      def self.find(body : Crystal::ASTNode, name : String) : Crystal::TypeDeclaration?
        finder = new(name)
        body.accept(finder)
        finder.found
      end

      def initialize(@name : String) : Nil
      end

      def visit(node : Crystal::TypeDeclaration) : Bool
        var = node.var
        @found = node if var.is_a?(Crystal::Var) && var.name == @name
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
