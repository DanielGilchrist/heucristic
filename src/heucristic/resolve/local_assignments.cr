require "compiler/crystal/syntax"

module Heucristic
  module Resolve
    class LocalAssignments < Crystal::Visitor
      getter values : Array(Crystal::ASTNode)

      def self.find(body : Crystal::ASTNode, name : String) : Array(Crystal::ASTNode)
        finder = new(name)
        body.accept(finder)
        finder.values
      end

      def initialize(@name : String) : Nil
        @values = Array(Crystal::ASTNode).new
      end

      def visit(node : Crystal::Assign) : Bool
        target = node.target
        @values << node.value if target.is_a?(Crystal::Var) && target.name == @name
        true
      end

      def visit(node : Crystal::Def) : Bool
        false
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end
    end
  end
end
