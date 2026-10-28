require "compiler/crystal/syntax"
require "./reassignment"

module Heucristic
  module Resolve
    class LocalAssignments < Crystal::Visitor
      getter targets : Array(Crystal::Var)
      getter located : Array(Reassignment)

      def self.locate(body : Crystal::ASTNode, name : String) : Array(Reassignment)
        finder = new(name)
        body.accept(finder)
        finder.located
      end

      def self.unpacked(node : Crystal::MultiAssign, name : String) : Crystal::ASTNode?
        index = node.targets.index { |target| target.is_a?(Crystal::Var) && target.name == name }
        return unless index
        return node.values[index]? if node.values.size == node.targets.size

        source = node.values[0]?
        return unless source && node.values.size == 1

        Crystal::Call.new(source, "[]", [Crystal::NumberLiteral.new(index)] of Crystal::ASTNode)
      end

      def self.assigned_value(node : Crystal::OpAssign) : Crystal::ASTNode
        node.op == "||" || node.op == "&&" ? node.value : node
      end

      def self.first_target(body : Crystal::ASTNode, name : String) : Crystal::Var?
        finder = new(name)
        body.accept(finder)
        finder.targets.first?
      end

      def initialize(@name : String) : Nil
        @targets = Array(Crystal::Var).new
        @located = Array(Reassignment).new
        @path = Array(Crystal::ASTNode).new
      end

      def visit_any(node : Crystal::ASTNode) : Bool
        @path << node
        true
      end

      def end_visit_any(node : Crystal::ASTNode) : Nil
        @path.pop
      end

      def visit(node : Crystal::Assign) : Bool
        target = node.target
        return true unless target.is_a?(Crystal::Var) && target.name == @name

        remember(node.value)
        @targets << target
        true
      end

      def visit(node : Crystal::OpAssign) : Bool
        target = node.target
        return true unless target.is_a?(Crystal::Var) && target.name == @name

        remember(LocalAssignments.assigned_value(node))
        @targets << target
        true
      end

      def visit(node : Crystal::MultiAssign) : Bool
        value = LocalAssignments.unpacked(node, @name)
        return true unless value

        remember(value)
        node.targets.each do |target|
          @targets << target if target.is_a?(Crystal::Var) && target.name == @name
        end
        true
      end

      def visit(node : Crystal::Def) : Bool
        false
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end

      private def remember(value : Crystal::ASTNode) : Nil
        @located << Reassignment.new(value, @path[1..])
      end
    end
  end
end
