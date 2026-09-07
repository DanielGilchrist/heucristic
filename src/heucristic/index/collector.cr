require "compiler/crystal/syntax"
require "../document/text"
require "./file"
require "./signature"

module Heucristic
  module Index
    class Collector < Crystal::Visitor
      def initialize(@path : String, @text : Document::Text) : Nil
        @defs = Array(Def).new
        @namespaces = Array(Namespace).new
        @mixins = Array(Mixin).new
        @instance_vars = Array(InstanceVar).new
        @aliases = Array(Alias).new
        @owners = Array(String).new
      end

      def self.collect(path : String, text : Document::Text, tree : Crystal::ASTNode) : File
        collector = new(path, text)
        tree.accept(collector)
        collector.file
      end

      def file : File
        File.new(@path, @defs, @namespaces, @mixins, @instance_vars, @aliases)
      end

      def visit(node : Crystal::ClassDef) : Bool
        name = enter(node.name)
        with_span(node.name) do |span|
          @namespaces << ClassNamespace.new(
            name: name,
            path: @path,
            name_span: span,
            kind: node.struct? ? ClassKind::Struct : ClassKind::Class,
            abstract_type: node.abstract?,
            type_vars: node.type_vars || Array(String).new,
            superclass: Restrictions.of(node.superclass),
          )
        end
        true
      end

      def visit(node : Crystal::ModuleDef) : Bool
        name = enter(node.name)
        with_span(node.name) do |span|
          @namespaces << ModuleNamespace.new(
            name: name,
            path: @path,
            name_span: span,
            type_vars: node.type_vars || Array(String).new,
          )
        end
        true
      end

      def visit(node : Crystal::EnumDef) : Bool
        name = enter(node.name)
        with_span(node.name) do |span|
          @namespaces << EnumNamespace.new(
            name: name, path: @path, name_span: span, base_type: Restrictions.of(node.base_type)
          )
        end
        true
      end

      def visit(node : Crystal::LibDef) : Bool
        name = enter(node.name)
        with_span(node.name) do |span|
          @namespaces << LibNamespace.new(name: name, path: @path, name_span: span)
        end
        true
      end

      def visit(node : Crystal::AnnotationDef) : Bool
        name = enter(node.name)
        with_span(node.name) do |span|
          @namespaces << AnnotationNamespace.new(name: name, path: @path, name_span: span)
        end
        false
      end

      def end_visit(
        node : Crystal::ClassDef | Crystal::ModuleDef | Crystal::EnumDef | Crystal::LibDef |
               Crystal::AnnotationDef,
      ) : Nil
        @owners.pop
      end

      def visit(node : Crystal::Include) : Bool
        @mixins << Mixin.new(owner, :include, Syntax::TypeReader.read(node.name), @path)
        false
      end

      def visit(node : Crystal::Extend) : Bool
        @mixins << Mixin.new(owner, :extend, Syntax::TypeReader.read(node.name), @path)
        false
      end

      def visit(node : Crystal::Alias) : Bool
        with_span(node.name) do |span|
          @aliases << Alias.new(
            qualify(node.name), Syntax::TypeReader.read(node.value), @path, span
          )
        end
        false
      end

      def visit(node : Crystal::TypeDeclaration) : Bool
        var = node.var
        return false unless var.is_a?(Crystal::InstanceVar)

        location = var.location
        return false unless location

        start = Document::Point.from(location)
        span = @text.span(start, start.advance(var.name.size))
        return false unless span.is_a?(Document::Span)

        @instance_vars << InstanceVar.new(
          var.name, owner, Syntax::TypeReader.read(node.declared_type), @path, span
        )
        false
      end

      def visit(node : Crystal::Def) : Bool
        record(node)
        true
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end

      private def owner : String
        @owners.last? || ""
      end

      private def qualify(name : Crystal::Path) : String
        own = name.names.join("::")
        return own if name.global? || @owners.empty?

        "#{owner}::#{own}"
      end

      private def enter(name : Crystal::Path) : String
        full = qualify(name)
        @owners << full
        full
      end

      private def with_span(name : Crystal::Path, & : Document::Span ->) : Nil
        location = name.location
        return unless location

        start = Document::Point.from(location)
        span = @text.span(start, start.advance(name.to_s.size))
        yield span if span.is_a?(Document::Span)
      end

      private def record(node : Crystal::Def) : Nil
        name_location = node.name_location
        return unless name_location

        start = Document::Point.from(name_location)
        span = @text.span(start, start.advance(node.name.size))
        return unless span.is_a?(Document::Span)

        @defs << Def.new(
          name: node.name,
          owner: owner,
          receiver: node.receiver ? Receiver::Metaclass : Receiver::Instance,
          path: @path,
          name_span: span,
          arity: Arity.of(node),
          parameters: Signature.parameters(node),
          return_type: Restrictions.of(node.return_type),
        )
      end
    end
  end
end
