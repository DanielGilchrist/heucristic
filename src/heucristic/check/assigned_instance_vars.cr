require "compiler/crystal/syntax"
require "../index/workspace"
require "./macro_arguments"
require "../syntax/well_known"

module Heucristic
  module Check
    class AssignedInstanceVars < Crystal::Visitor
      record Undecidable

      def self.of(body : Crystal::ASTNode, workspace : Index::Workspace) : Set(String) | Undecidable
        visitor = new(workspace)
        body.accept(visitor)
        visitor.undecidable? ? Undecidable.new : visitor.names
      end

      getter names : Set(String)
      getter? undecidable : Bool

      def initialize(@workspace : Index::Workspace) : Nil
        @names = Set(String).new
        @undecidable = false
      end

      def visit(node : Crystal::Assign | Crystal::OpAssign) : Bool
        target = node.target
        @names << target.name if target.is_a?(Crystal::InstanceVar)
        true
      end

      def visit(node : Crystal::MultiAssign) : Bool
        node.targets.each { |target| @names << target.name if target.is_a?(Crystal::InstanceVar) }
        true
      end

      def visit(node : Crystal::Call) : Bool
        return true unless node.obj.nil?

        macro_like = MacroArguments.macro_like?(node.name, @workspace)
        @undecidable = true if macro_like || super_like?(node.name)
        true
      end

      def visit(node : Crystal::MacroExpression | Crystal::MacroIf | Crystal::MacroFor) : Bool
        @undecidable = true
        false
      end

      def visit(node : Crystal::Def) : Bool
        false
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end

      private def super_like?(name : String) : Bool
        known = Syntax::WellKnown.from_name(name)
        !known.nil? && (known.super? || known.previous_def?)
      end
    end
  end
end
