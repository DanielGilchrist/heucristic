require "compiler/crystal/syntax"

module Heucristic
  module Syntax
    class MacroCode < Crystal::Visitor
      getter paths : Array(Crystal::Path)

      def self.paths(node : Crystal::ASTNode) : Array(Crystal::Path)
        collector = new
        node.accept(collector)
        collector.paths
      end

      def initialize : Nil
        @paths = Array(Crystal::Path).new
      end

      def visit(node : Crystal::Path) : Bool
        @paths << node
        false
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end
    end
  end
end
