require "compiler/crystal/syntax"
require "../document/point"
require "./scoped"

module Heucristic
  module Syntax
    class Cursor < Scoped
      getter target : Target?

      def initialize(@point : Document::Point) : Nil
        super()
      end

      def self.find(tree : Crystal::ASTNode, point : Document::Point) : Target?
        cursor = new(point)
        tree.accept(cursor)
        cursor.target
      end

      def visit(node : Crystal::Def) : Bool
        super
        @target = OnDef.new(node, context) if over?(node.name_location, node.name.size)
        @target.nil?
      end

      def visit(node : Crystal::Call) : Bool
        @target = OnCall.new(node, context) if over?(node.name_location, node.name.size)
        super
        @target.nil?
      end

      def visit(node : Crystal::Path) : Bool
        if (location = node.location) && over?(location, node.to_s.size)
          @target = OnPath.new(node, context, segment_at(node, location))
        end
        @target.nil?
      end

      def visit(node : Crystal::Var) : Bool
        @target = OnVar.new(node.name, context) if over?(node.location, node.name.size)
        @target.nil?
      end

      def visit(node : Crystal::Arg) : Bool
        @target = OnVar.new(node.name, context) if over?(node.location, node.name.size + 1)
        @target.nil?
      end

      def visit(node : Crystal::InstanceVar) : Bool
        @target = OnInstanceVar.new(node.name, context) if over?(node.location, node.name.size)
        @target.nil?
      end

      def visit(
        node : Crystal::ClassDef | Crystal::ModuleDef | Crystal::EnumDef | Crystal::LibDef,
      ) : Bool
        super
        @target.nil?
      end

      def visit(node : Crystal::MacroIf) : Bool
        return false unless @target.nil?

        super
      end

      def visit(node : Crystal::ASTNode) : Bool
        @target.nil?
      end

      private def segment_at(node : Crystal::Path, location : Crystal::Location) : Int32
        offset = @point.column - location.column_number - (node.global? ? 2 : 0)
        node.names.each_with_index do |name, index|
          return index if offset < name.size
          offset -= name.size + 2
        end
        node.names.size - 1
      end

      private def over?(location : Crystal::Location?, size : Int32) : Bool
        return false unless location

        start = Document::Point.from(location)
        @point >= start && @point < start.advance(size)
      end
    end
  end
end
