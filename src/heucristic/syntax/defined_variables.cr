require "compiler/crystal/syntax"

module Heucristic
  module Syntax
    class DefinedVariables < Crystal::Visitor
      getter names : Set(String)

      def self.of(definition : Crystal::Def) : Set(String)
        finder = new
        definition.args.each { |argument| finder.names << argument.name }
        definition.block_arg.try { |block| finder.names << block.name }
        definition.body.accept(finder)
        finder.names
      end

      def self.at_top_level(tree : Crystal::ASTNode) : Set(String)
        finder = new
        tree.accept(finder)
        finder.names
      end

      def initialize : Nil
        @names = Set(String).new
      end

      def visit(node : Crystal::Assign | Crystal::OpAssign) : Bool
        target = node.target
        @names << target.name if target.is_a?(Crystal::Var)
        true
      end

      def visit(node : Crystal::MultiAssign) : Bool
        node.targets.each { |target| @names << target.name if target.is_a?(Crystal::Var) }
        true
      end

      def visit(node : Crystal::Block) : Bool
        node.args.each { |argument| @names << argument.name }
        true
      end

      def visit(node : Crystal::Rescue) : Bool
        node.name.try { |name| @names << name }
        true
      end

      def visit(node : Crystal::UninitializedVar | Crystal::TypeDeclaration) : Bool
        var = node.var
        @names << var.name if var.is_a?(Crystal::Var)
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
