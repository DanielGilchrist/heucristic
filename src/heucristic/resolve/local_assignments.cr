require "compiler/crystal/syntax"

module Heucristic
  module Resolve
    class LocalAssignments < Crystal::Visitor
      getter values : Array(Crystal::ASTNode)
      getter targets : Array(Crystal::Var)

      def self.find(body : Crystal::ASTNode, name : String) : Array(Crystal::ASTNode)
        finder = new(name)
        body.accept(finder)
        finder.values
      end

      def self.first_target(body : Crystal::ASTNode, name : String) : Crystal::Var?
        finder = new(name)
        body.accept(finder)
        finder.targets.first?
      end

      def initialize(@name : String) : Nil
        @values = Array(Crystal::ASTNode).new
        @targets = Array(Crystal::Var).new
      end

      def visit(node : Crystal::Assign | Crystal::OpAssign) : Bool
        target = node.target
        return true unless target.is_a?(Crystal::Var) && target.name == @name

        @values << node.value
        @targets << target
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
