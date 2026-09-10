require "compiler/crystal/syntax"

module Heucristic
  module Resolve
    class RescueVariables < Crystal::Visitor
      getter found : Crystal::Rescue?

      def self.find(body : Crystal::ASTNode, name : String) : Crystal::Rescue?
        finder = new(name)
        body.accept(finder)
        finder.found
      end

      def initialize(@name : String) : Nil
      end

      def visit(node : Crystal::Rescue) : Bool
        @found = node if node.name == @name
        @found.nil?
      end

      def visit(node : Crystal::Def) : Bool
        false
      end

      def visit(node : Crystal::ASTNode) : Bool
        @found.nil?
      end
    end
  end
end
