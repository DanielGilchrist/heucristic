require "compiler/crystal/syntax"
require "../document/point"
require "./target"

module Heucristic
  module Syntax
    class Cursor < Crystal::Visitor
      getter target : Target?

      def initialize(@point : Document::Point) : Nil
        @enclosing = Array(String).new
        @type_vars = Array(String).new
      end

      def self.find(tree : Crystal::ASTNode, point : Document::Point) : Target?
        cursor = new(point)
        tree.accept(cursor)
        cursor.target
      end

      def visit(node : Crystal::Def) : Bool
        @type_vars.concat(node.free_vars || Array(String).new)
        @target = OnDef.new(node) if over?(node.name_location, node.name.size)
        @target.nil?
      end

      def end_visit(node : Crystal::Def) : Nil
        (node.free_vars || Array(String).new).size.times { @type_vars.pop }
      end

      def visit(node : Crystal::Call) : Bool
        @target = OnCall.new(node) if over?(node.name_location, node.name.size)
        @target.nil?
      end

      def visit(node : Crystal::Path) : Bool
        if over?(node.location, node.to_s.size)
          @target = OnPath.new(node, @enclosing.dup, @type_vars.dup)
        end
        @target.nil?
      end

      def visit(
        node : Crystal::ClassDef | Crystal::ModuleDef | Crystal::EnumDef | Crystal::LibDef,
      ) : Bool
        @enclosing << qualify(node.name)
        @type_vars.concat(type_vars_of(node))
        @target.nil?
      end

      def end_visit(
        node : Crystal::ClassDef | Crystal::ModuleDef | Crystal::EnumDef | Crystal::LibDef,
      ) : Nil
        @enclosing.pop
        type_vars_of(node).size.times { @type_vars.pop }
      end

      private def type_vars_of(node : Crystal::ASTNode) : Array(String)
        case node
        when Crystal::ClassDef, Crystal::ModuleDef then node.type_vars || Array(String).new
        else                                            Array(String).new
        end
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
