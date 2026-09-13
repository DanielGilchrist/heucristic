require "compiler/crystal/syntax"
require "./macro_effect"

module Heucristic
  module Index
    class MacroBody < Crystal::Visitor
      KEYWORDS = %w[
        def fun class struct module enum lib annotation alias include extend macro abstract private
        protected getter property setter class_getter class_property class_setter record delegate
        forward_missing_to method_missing previous_def
      ]
      DECLARING_WORDS = /(?<![\w@.])(?:#{KEYWORDS.join('|')})(?![\w?!])|@\w+\s*[:=]/

      record Traits, effect : MacroEffect, splices_block : Bool

      def self.of(node : Crystal::Macro) : Traits
        visitor = new(node.block_arg.try(&.name))
        node.body.accept(visitor)
        visitor.traits
      end

      def self.effect(node : Crystal::Macro) : MacroEffect
        of(node).effect
      end

      getter effect : MacroEffect

      def initialize(@block_name : String?) : Nil
        @effect = MacroEffect::Expression
        @splices = 0
        @other_block_uses = 0
      end

      def traits : Traits
        Traits.new(@effect, @effect.expression? && @splices > 0 && @other_block_uses == 0)
      end

      def visit(node : Crystal::MacroLiteral) : Bool
        @effect = MacroEffect::Declaring if node.value.matches?(DECLARING_WORDS)
        false
      end

      def visit(node : Crystal::MacroExpression) : Bool
        exp = node.exp
        if splice?(exp)
          @splices += 1
        else
          @effect = MacroEffect::Declaring unless exp.is_a?(Crystal::Var)
          exp.accept(BlockUses.new(@block_name, self))
        end
        false
      end

      def block_used : Nil
        @other_block_uses += 1
      end

      def visit(node : Crystal::MacroVar) : Bool
        @effect = MacroEffect::Declaring
        false
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end

      private def splice?(exp : Crystal::ASTNode) : Bool
        return true if exp.is_a?(Crystal::Yield) && exp.exps.empty?
        return false unless exp.is_a?(Crystal::Call) && exp.name == "body" && exp.args.empty?

        receiver = exp.obj
        receiver.is_a?(Crystal::Var) && receiver.name == @block_name
      end

      class BlockUses < Crystal::Visitor
        def initialize(@block_name : String?, @owner : MacroBody) : Nil
        end

        def visit(node : Crystal::Var) : Bool
          @owner.block_used if node.name == @block_name
          false
        end

        def visit(node : Crystal::ASTNode) : Bool
          true
        end
      end
    end
  end
end
