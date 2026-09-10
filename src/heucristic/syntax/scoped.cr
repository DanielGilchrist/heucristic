require "compiler/crystal/syntax"
require "./target"
require "../syntax"
require "../index/macro_text"

module Heucristic
  module Syntax
    class Scoped < Crystal::Visitor
      def initialize : Nil
        @enclosing = Array(String).new
        @type_vars = Array(String).new
        @defs = Array(Crystal::Def).new
        @blocks = Array(Crystal::Call).new
        @nodes = Array(Crystal::ASTNode).new
      end

      def initialize(
        enclosing : Array(String),
        type_vars : Array(String),
        definition : Crystal::Def,
      ) : Nil
        @enclosing = enclosing.dup
        @type_vars = type_vars.dup
        @defs = [definition]
        @blocks = Array(Crystal::Call).new
        @nodes = Array(Crystal::ASTNode).new
      end

      def visit_any(node : Crystal::ASTNode) : Bool
        @nodes << node
        true
      end

      def end_visit_any(node : Crystal::ASTNode) : Nil
        @nodes.pop
      end

      def visit(node : Crystal::Def) : Bool
        @defs << node
        @type_vars.concat(node.free_vars || Array(String).new)
        true
      end

      def end_visit(node : Crystal::Def) : Nil
        @defs.pop
        (node.free_vars || Array(String).new).size.times { @type_vars.pop }
      end

      def visit(node : Crystal::Call) : Bool
        @blocks << node if node.block
        if (name = record_name(node))
          @enclosing << qualify(name)
        end
        true
      end

      def end_visit(node : Crystal::Call) : Nil
        @blocks.pop if node.block
        @enclosing.pop if record_name(node)
      end

      def visit(
        node : Crystal::ClassDef | Crystal::ModuleDef | Crystal::EnumDef | Crystal::LibDef,
      ) : Bool
        @enclosing << qualify(node.name)
        @type_vars.concat(type_vars_of(node))
        true
      end

      def visit(node : Crystal::Macro | Crystal::MacroFor | Crystal::MacroExpression) : Bool
        false
      end

      def visit(node : Crystal::MacroIf) : Bool
        expanded = Index::MacroText.expand(node)
        return false if expanded.is_a?(Index::MacroText::Undecidable)
        location = node.location
        return false unless location

        fragment = Syntax.parse_fragment(expanded, "", location)
        fragment.accept(self) unless fragment.is_a?(Syntax::Broken)
        false
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end

      def end_visit(
        node : Crystal::ClassDef | Crystal::ModuleDef | Crystal::EnumDef | Crystal::LibDef,
      ) : Nil
        @enclosing.pop
        type_vars_of(node).size.times { @type_vars.pop }
      end

      protected def context : Context
        Context.new(@enclosing.dup, @type_vars.dup, @defs.last?, @blocks.dup, @nodes.dup)
      end

      private def record_name(node : Crystal::Call) : Crystal::Path?
        return unless node.name == "record" && node.obj.nil?

        name = node.args[0]?
        name.is_a?(Crystal::Path) ? name : nil
      end

      private def type_vars_of(node : Crystal::ASTNode) : Array(String)
        case node
        when Crystal::ClassDef, Crystal::ModuleDef then node.type_vars || Array(String).new
        else                                            Array(String).new
        end
      end

      private def qualify(name : Crystal::Path) : String
        own = name.names.join("::")
        return own if name.global? || @enclosing.empty?

        "#{@enclosing.last}::#{own}"
      end
    end
  end
end
