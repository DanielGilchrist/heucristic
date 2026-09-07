require "compiler/crystal/syntax"
require "../document/point"
require "./target"

module Heucristic
  module Syntax
    class Cursor < Crystal::Visitor
      getter target : Target?

      def initialize(@point : Document::Point) : Nil
        @enclosing = Array(String).new
      end

      def self.find(tree : Crystal::ASTNode, point : Document::Point) : Target?
        cursor = new(point)
        tree.accept(cursor)
        cursor.target
      end

      def visit(node : Crystal::Def) : Bool
        @target = OnDef.new(node) if over?(node.name_location, node.name.size)
        @target.nil?
      end

      def visit(node : Crystal::Call) : Bool
        @target = OnCall.new(node) if over?(node.name_location, node.name.size)
        @target.nil?
      end

      def visit(node : Crystal::Path) : Bool
        @target = OnPath.new(node, @enclosing.dup) if over?(node.location, node.to_s.size)
        @target.nil?
      end

      def visit(
        node : Crystal::ClassDef | Crystal::ModuleDef | Crystal::EnumDef | Crystal::LibDef,
      ) : Bool
        @enclosing << qualify(node.name)
        @target.nil?
      end

      def end_visit(
        node : Crystal::ClassDef | Crystal::ModuleDef | Crystal::EnumDef | Crystal::LibDef,
      ) : Nil
        @enclosing.pop
      end

      def visit(node : Crystal::ASTNode) : Bool
        @target.nil?
      end

      private def qualify(name : Crystal::Path) : String
        own = name.names.join("::")
        return own if name.global? || @enclosing.empty?

        "#{@enclosing.last}::#{own}"
      end

      private def over?(location : Crystal::Location?, size : Int32) : Bool
        return false unless location

        start = Document::Point.from(location)
        @point >= start && @point < start.advance(size)
      end
    end
  end
end
