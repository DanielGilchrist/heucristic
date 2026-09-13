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

      def self.effect(node : Crystal::Macro) : MacroEffect
        visitor = new
        node.body.accept(visitor)
        visitor.effect
      end

      getter effect : MacroEffect

      def initialize : Nil
        @effect = MacroEffect::Expression
      end

      def visit(node : Crystal::MacroLiteral) : Bool
        @effect = MacroEffect::Declaring if node.value.matches?(DECLARING_WORDS)
        false
      end

      def visit(node : Crystal::MacroExpression) : Bool
        @effect = MacroEffect::Declaring unless node.exp.is_a?(Crystal::Var)
        false
      end

      def visit(node : Crystal::MacroVar) : Bool
        @effect = MacroEffect::Declaring
        false
      end

      def visit(node : Crystal::ASTNode) : Bool
        !@effect.declaring?
      end
    end
  end
end
