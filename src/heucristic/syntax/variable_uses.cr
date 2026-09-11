require "compiler/crystal/syntax"

module Heucristic
  module Syntax
    class VariableUses < Crystal::Visitor
      getter locations : Array(Crystal::Location)

      def self.of(body : Crystal::ASTNode, name : String) : Array(Crystal::Location)
        finder = new(name)
        body.accept(finder)
        finder.locations
      end

      def initialize(@name : String) : Nil
        @locations = Array(Crystal::Location).new
      end

      def visit(node : Crystal::Var) : Bool
        keep(node.location) if node.name == @name
        true
      end

      def visit(node : Crystal::Arg) : Bool
        keep(node.location) if node.name == @name
        true
      end

      def visit(node : Crystal::Def) : Bool
        false
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end

      private def keep(location : Crystal::Location?) : Nil
        @locations << location if location
      end
    end
  end
end
