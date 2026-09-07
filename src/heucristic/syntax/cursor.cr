require "compiler/crystal/syntax"
require "../document/point"
require "./target"

module Heucristic
  module Syntax
    class Cursor < Crystal::Visitor
      getter target : Target?

      def initialize(@point : Document::Point) : Nil
      end

      def self.find(tree : Crystal::ASTNode, point : Document::Point) : Target?
        cursor = new(point)
        tree.accept(cursor)
        cursor.target
      end

      def visit(node : Crystal::Def) : Bool
        @target = OnDef.new(node) if over_name?(node.name_location, node.name.size)
        @target.nil?
      end

      def visit(node : Crystal::Call) : Bool
        @target = OnCall.new(node) if over_name?(node.name_location, node.name.size)
        @target.nil?
      end

      def visit(node : Crystal::ASTNode) : Bool
        @target.nil?
      end

      private def over_name?(name_location : Crystal::Location?, size : Int32) : Bool
        return false unless name_location

        start = Document::Point.from(name_location)
        @point >= start && @point < start.advance(size)
      end
    end
  end
end
