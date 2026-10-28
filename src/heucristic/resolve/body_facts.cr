require "compiler/crystal/syntax"
require "./reassignment"
require "./local_assignments"

module Heucristic
  module Resolve
    class BodyFacts < Crystal::Visitor
      record Scoped, name : String, body : UInt64

      def self.of(body : Crystal::ASTNode) : BodyFacts
        facts = new
        body.accept(facts)
        facts
      end

      def initialize : Nil
        @assignments = Hash(String, Array(Crystal::ASTNode)).new
        @reassignments = Hash(String, Array(Reassignment)).new
        @declarations = Hash(String, Crystal::TypeDeclaration).new
        @rescues = Hash(String, Crystal::Rescue).new
        @mentioned = Hash(String, Set(UInt64)).new
        @within = Hash(String, Hash(UInt64, Array(Reassignment))).new
        @outside = Hash(Scoped, Bool).new
        @statements = Hash(Scoped, Array(Int32)).new
        @path = Array(Crystal::ASTNode).new
      end

      def mentioning_in(name : String, block : Crystal::Expressions) : Array(Int32)
        key = Scoped.new(name, block.object_id)
        @statements.fetch(key) { @statements[key] = statements_mentioning(name, block) }
      end

      def defined_outside?(name : String, body : Crystal::ASTNode, & : -> Bool) : Bool
        key = Scoped.new(name, body.object_id)
        @outside.fetch(key) { @outside[key] = yield }
      end

      def assigned(name : String) : Array(Crystal::ASTNode)
        @assignments[name]? || Array(Crystal::ASTNode).new
      end

      def reassigned(name : String) : Array(Reassignment)
        @reassignments[name]? || Array(Reassignment).new
      end

      def reassigned_within(name : String, statement : Crystal::ASTNode) : Array(Reassignment)
        by_ancestor = @within[name] ||= index_within(name)
        by_ancestor[statement.object_id]? || Array(Reassignment).new
      end

      def declaration(name : String) : Crystal::TypeDeclaration?
        @declarations[name]?
      end

      def rescued(name : String) : Crystal::Rescue?
        @rescues[name]?
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
        remember(target.name, node.value) if target.is_a?(Crystal::Var)
        true
      end

      def visit(node : Crystal::OpAssign) : Bool
        target = node.target
        remember(target.name, LocalAssignments.assigned_value(node)) if target.is_a?(Crystal::Var)
        true
      end

      def visit(node : Crystal::MultiAssign) : Bool
        node.targets.each do |target|
          next unless target.is_a?(Crystal::Var)

          value = LocalAssignments.unpacked(node, target.name)
          remember(target.name, value) if value
        end
        true
      end

      def visit(node : Crystal::TypeDeclaration) : Bool
        var = node.var
        @declarations[var.name] ||= node if var.is_a?(Crystal::Var)
        true
      end

      def visit(node : Crystal::Rescue) : Bool
        name = node.name
        @rescues[name] ||= node if name
        true
      end

      def visit(node : Crystal::Var) : Bool
        containing = @mentioned[node.name] ||= Set(UInt64).new
        @path.each { |ancestor| containing << ancestor.object_id }
        true
      end

      def visit(node : Crystal::Def) : Bool
        false
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end

      private def remember(name : String, value : Crystal::ASTNode) : Nil
        (@assignments[name] ||= Array(Crystal::ASTNode).new) << value
        (@reassignments[name] ||= Array(Reassignment).new) << Reassignment.new(value, @path[1..])
      end

      private def statements_mentioning(name : String, block : Crystal::Expressions) : Array(Int32)
        indices = Array(Int32).new
        containing = @mentioned[name]?
        return indices unless containing

        block.expressions.each_with_index do |statement, index|
          indices << index if containing.includes?(statement.object_id)
        end
        indices
      end

      private def index_within(name : String) : Hash(UInt64, Array(Reassignment))
        by_ancestor = Hash(UInt64, Array(Reassignment)).new
        reassigned(name).each do |item|
          item.path.each_with_index do |ancestor, position|
            below = Reassignment.new(item.value, item.path[(position + 1)..])
            (by_ancestor[ancestor.object_id] ||= Array(Reassignment).new) << below
          end
        end
        by_ancestor
      end
    end
  end
end
