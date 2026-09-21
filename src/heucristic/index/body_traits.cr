require "compiler/crystal/syntax"

module Heucristic
  module Index
    class BodyTraits < Crystal::Visitor
      record Traits, with_yield : Bool, macro_body : Bool, exit_call : String?

      def self.of(node : Crystal::Def) : Traits
        visitor = new
        node.body.accept(visitor)
        Traits.new(visitor.with_yield?, visitor.macro_body?, exit_call(node.body))
      end

      def self.exit_call(body : Crystal::ASTNode) : String?
        last = body.is_a?(Crystal::Expressions) ? body.expressions.last? : body
        return unless last.is_a?(Crystal::Call) && last.obj.nil? && last.block.nil?

        last.name
      end

      getter? with_yield : Bool
      getter? macro_body : Bool

      def initialize : Nil
        @with_yield = false
        @macro_body = false
      end

      def visit(node : Crystal::Yield) : Bool
        @with_yield = true unless node.scope.nil?
        true
      end

      def visit(node : Crystal::MacroExpression | Crystal::MacroIf | Crystal::MacroFor) : Bool
        @macro_body = true
        false
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end
    end
  end
end
