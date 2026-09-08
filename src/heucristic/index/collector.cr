require "compiler/crystal/syntax"
require "../document/text"
require "./file"
require "./signature"
require "./evident"

module Heucristic
  module Index
    class Collector < Crystal::Visitor
      def initialize(@path : String, @text : Document::Text) : Nil
        @defs = Array(Def).new
        @namespaces = Array(Namespace).new
        @mixins = Array(Mixin).new
        @instance_vars = Array(InstanceVar).new
        @aliases = Array(Alias).new
        @constants = Array(Constant).new
        @owners = Array(String).new
      end

      def self.collect(path : String, text : Document::Text, tree : Crystal::ASTNode) : File
        collector = new(path, text)
        tree.accept(collector)
        collector.file
      end

      def file : File
        File.new(@path, @defs, @namespaces, @mixins, @instance_vars, @aliases, @constants)
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
        mixin(:include, node.name)
      end

      def visit(node : Crystal::Extend) : Bool
        mixin(:extend, node.name)
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

        instance_var(var.name, Syntax::TypeReader.read(node.declared_type), span, :declared)
        false
      end

      def visit(node : Crystal::Assign) : Bool
        target = node.target
        return constant(target, node.value) if target.is_a?(Crystal::Path)
        return true unless target.is_a?(Crystal::InstanceVar)

        type = Evident.type(node.value)
        return true if type.is_a?(Evident::NotEvident)

        location = target.location
        return true unless location

        start = Document::Point.from(location)
        span = @text.span(start, start.advance(target.name.size))
        return true unless span.is_a?(Document::Span)

        instance_var(target.name, type, span, :assigned)
        true
      end

      def visit(node : Crystal::Def) : Bool
        record(node)
        true
      end

      def visit(node : Crystal::Call) : Bool
        return true unless node.name == "record" && node.obj.nil?
        name = node.args[0]?
        return true unless name.is_a?(Crystal::Path)

        full = enter(name)
        with_span(name) do |span|
          @namespaces << ClassNamespace.new(
            name: full,
            path: @path,
            name_span: span,
            kind: :struct,
            abstract_type: false,
            type_vars: Array(String).new,
            superclass: Unrestricted.new,
          )
        end
        node.args.skip(1).each { |field| record_field(field) }
        node.block.try(&.accept(self))
        @owners.pop
        false
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end

      private def constant(name : Crystal::Path, value : Crystal::ASTNode) : Bool
        with_span(name) do |span|
          @constants << Constant.new(qualify(name), @path, span, value.to_s, Evident.type(value))
        end
        false
      end

      private def owner : Owner
        @owners.last? || TopLevel.new
      end

      private def mixin(kind : MixinKind, target : Crystal::ASTNode) : Bool
        namespace = owner
        return false if namespace.is_a?(TopLevel)

        @mixins << Mixin.new(namespace, kind, Syntax::TypeReader.read(target), @path)
        false
      end

      private def instance_var(
        name : String,
        type : Syntax::TypeReader::Outcome,
        span : Document::Span,
        origin : Origin,
      ) : Nil
        namespace = owner
        return if namespace.is_a?(TopLevel)

        @instance_vars << InstanceVar.new(name, namespace, type, @path, span, origin)
      end

      private def qualify(name : Crystal::Path) : String
        own = name.names.join("::")
        case (namespace = owner)
        in TopLevel then own
        in String   then name.global? ? own : "#{namespace}::#{own}"
        end
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

      private def record_ivar_parameters(node : Crystal::Def) : Nil
        body = node.body
        statements = body.is_a?(Crystal::Expressions) ? body.expressions : [body]
        statements.each do |statement|
          break unless statement.is_a?(Crystal::Assign)
          target = statement.target
          value = statement.value
          break unless target.is_a?(Crystal::InstanceVar) && value.is_a?(Crystal::Var)

          parameter = node.args.find(&.name.==(value.name))
          restriction = parameter.try(&.restriction)
          next unless parameter && restriction

          location = parameter.location
          next unless location

          start = Document::Point.from(location)
          span = @text.span(start, start.advance(target.name.size))
          next unless span.is_a?(Document::Span)

          instance_var(target.name, Syntax::TypeReader.read(restriction), span, :declared)
        end
      end

      private def record_field(field : Crystal::ASTNode) : Nil
        return unless field.is_a?(Crystal::TypeDeclaration)
        var = field.var
        return unless var.is_a?(Crystal::Var)
        location = var.location
        return unless location

        start = Document::Point.from(location)
        span = @text.span(start, start.advance(var.name.size))
        return unless span.is_a?(Document::Span)

        type = Syntax::TypeReader.read(field.declared_type)
        instance_var("@#{var.name}", type, span, :declared)
        @defs << Def.new(
          name: var.name,
          owner: owner,
          receiver: :instance,
          path: @path,
          name_span: span,
          arity: Arity.new(0, 0, false),
          parameters: Array(Parameter).new,
          return_type: type,
          free_vars: Array(String).new,
          yields: false,
        )
      end

      private def record(node : Crystal::Def) : Nil
        record_ivar_parameters(node)
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
          free_vars: node.free_vars || Array(String).new,
          yields: !node.block_arity.nil? || !node.block_arg.nil?,
        )
      end
    end
  end
end
