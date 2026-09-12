require "compiler/crystal/syntax"
require "./reassignment"
require "./local_assignments"

module Heucristic
  module Resolve
    class BodyFacts < Crystal::Visitor
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
        @path = Array(Crystal::ASTNode).new
      end

      def mentions?(name : String, node : Crystal::ASTNode) : Bool
        containing = @mentioned[name]?
        !containing.nil? && containing.includes?(node.object_id)
      end

      def assigned(name : String) : Array(Crystal::ASTNode)
        @assignments[name]? || Array(Crystal::ASTNode).new
      end

      def reassigned(name : String) : Array(Reassignment)
        @reassignments[name]? || Array(Reassignment).new
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

      def visit(node : Crystal::Assign | Crystal::OpAssign) : Bool
        target = node.target
        remember(target.name, node.value) if target.is_a?(Crystal::Var)
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
    end
  end
end
