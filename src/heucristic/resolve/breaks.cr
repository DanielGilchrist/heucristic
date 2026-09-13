require "compiler/crystal/syntax"

module Heucristic
  module Resolve
    class Breaks < Crystal::Visitor
      record Found, node : Crystal::Break, ancestors : Array(Crystal::ASTNode)

      getter found : Array(Found)

      def self.in(block : Crystal::Block) : Array(Found)
        visitor = new
        block.body.accept(visitor)
        visitor.found
      end

      def initialize : Nil
        @found = Array(Found).new
        @stack = Array(Crystal::ASTNode).new
      end

      def visit(node : Crystal::Break) : Bool
        @found << Found.new(node, @stack.dup)
        @stack << node
        false
      end

      def visit(
        node : Crystal::While | Crystal::Until | Crystal::Block | Crystal::ProcLiteral |
               Crystal::Def,
      ) : Bool
        @stack << node
        false
      end

      def visit(node : Crystal::ASTNode) : Bool
        @stack << node
        true
      end

      def end_visit(node : Crystal::ASTNode) : Nil
        @stack.pop
      end
    end
  end
end
