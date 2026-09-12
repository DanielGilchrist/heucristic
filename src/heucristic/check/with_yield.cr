require "compiler/crystal/syntax"
require "../index/def"

module Heucristic
  module Check
    class WithYield < Crystal::Visitor
      def self.in?(entry : Index::Def) : Bool
        node = entry.node
        return false unless node

        visitor = new
        node.body.accept(visitor)
        visitor.scoped_yield?
      end

      def self.macro_body?(entry : Index::Def) : Bool
        node = entry.node
        return false unless node

        visitor = new
        node.body.accept(visitor)
        visitor.macro_expression?
      end

      getter? scoped_yield : Bool
      getter? macro_expression : Bool

      def initialize : Nil
        @scoped_yield = false
        @macro_expression = false
      end

      def visit(node : Crystal::Yield) : Bool
        @scoped_yield = true unless node.scope.nil?
        true
      end

      def visit(node : Crystal::MacroExpression | Crystal::MacroIf | Crystal::MacroFor) : Bool
        @macro_expression = true
        false
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end
    end
  end
end
