require "compiler/crystal/syntax"
require "../document/text"
require "./file"
require "./signature"

module Heucristic
  module Index
    class Collector < Crystal::Visitor
      def initialize(@path : String, @text : Document::Text) : Nil
        @defs = Array(Def).new
        @owners = Array(String).new
      end

      def self.collect(path : String, text : Document::Text, tree : Crystal::ASTNode) : File
        collector = new(path, text)
        tree.accept(collector)
        File.new(path, collector.@defs)
      end

      def visit(node : Crystal::ClassDef) : Bool
        enter(node.name)
      end

      def visit(node : Crystal::ModuleDef) : Bool
        enter(node.name)
      end

      def visit(node : Crystal::EnumDef) : Bool
        enter(node.name)
      end

      def visit(node : Crystal::LibDef) : Bool
        enter(node.name)
      end

      def end_visit(
        node : Crystal::ClassDef | Crystal::ModuleDef | Crystal::EnumDef | Crystal::LibDef,
      ) : Nil
        @owners.pop
      end

      def visit(node : Crystal::Def) : Bool
        record(node)
        false
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end

      private def enter(name : Crystal::Path) : Bool
        @owners << name.names.join("::")
        true
      end

      private def record(node : Crystal::Def) : Nil
        name_location = node.name_location
        return unless name_location

        start = Document::Point.from(name_location)
        span = @text.span(start, start.advance(node.name.size))
        return unless span.is_a?(Document::Span)

        @defs << Def.new(
          name: node.name,
          owner: @owners.join("::"),
          receiver: node.receiver ? Receiver::Metaclass : Receiver::Instance,
          path: @path,
          name_span: span,
          arity: Arity.of(node),
          signature: Signature.of(node),
        )
      end
    end
  end
end
