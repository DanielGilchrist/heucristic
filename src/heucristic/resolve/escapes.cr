require "compiler/crystal/syntax"

module Heucristic
  module Resolve
    class Escapes < Crystal::Visitor
      record Found, node : Crystal::Break | Crystal::Next, ancestors : Array(Crystal::ASTNode)

      getter breaks : Array(Found)
      getter nexts : Array(Found)

      def self.in(block : Crystal::Block) : Escapes
        visitor = new
        block.body.accept(visitor)
        visitor
      end

      def initialize : Nil
        @breaks = Array(Found).new
        @nexts = Array(Found).new
        @stack = Array(Crystal::ASTNode).new
      end

      def visit(node : Crystal::Break) : Bool
        @breaks << Found.new(node, @stack.dup)
        @stack << node
        false
      end

      def visit(node : Crystal::Next) : Bool
        @nexts << Found.new(node, @stack.dup)
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
