require "compiler/crystal/syntax"
require "../document/text"
require "./accessor"
require "./def"
require "./evident"
require "./instance_var"
require "./instance_var_read"
require "./macro_hook"
require "./visibility"
require "../syntax"
require "../syntax/well_known"

module Heucristic
  module Index
    struct DeclarationMacros
      def initialize(
        @owner : String,
        @path : String,
        @text : Document::Text,
        @visibility : Visibility,
        @definition : Crystal::Def?,
        @defs : Array(Def),
        @instance_vars : Array(InstanceVar),
      ) : Nil
      end

      def accessors(node : Crystal::Call, accessor : Accessor) : Nil
        lazy = !node.block.nil?
        node.args.each { |arg| accessor(arg, accessor, lazy) }
      end

      def delegates(node : Crystal::Call) : Nil
        target = node.named_args.try(&.find(&.name.==("to"))).try(&.value)
        return unless target

        node.args.each do |arg|
          name = case arg
                 in Crystal::SymbolLiteral, Crystal::StringLiteral then arg.value
                 in Crystal::Call
                   arg.obj.nil? && arg.args.empty? ? arg.name : nil
                 in Crystal::ASTNode then nil
                 end
          next unless name
          span = span_of(arg, name.size + 1)
          next unless span

          @defs << Def.forwarder(name, @owner, @path, span, target)
        end
      end

      def forward(node : Crystal::Call) : Nil
        target = node.args[0]?
        return unless target

        span = span_of(node, node.name.size)
        return unless span

        @defs << Def.forwarder(MacroHook::MethodMissing.macro_name, @owner, @path, span, target)
      end

      def record_declared(name : Crystal::Path, fields : Array(Crystal::ASTNode)) : Nil
        fields.each { |field| record_field(field) }
        record_initializer(name, fields)
        record_copies(name)
      end

      def c_field(field : Crystal::ASTNode) : Nil
        record_field(field)
        return unless field.is_a?(Crystal::TypeDeclaration)
        var = field.var
        return unless var.is_a?(Crystal::Var)
        location = var.location
        return unless location

        start = Document::Point.from(location)
        span = @text.span(start, start.advance(var.name.size))
        return unless span.is_a?(Document::Span)

        type = Syntax::TypeReader.read(field.declared_type)
        @defs << Def.synthetic(
          name: "#{var.name}=",
          owner: @owner,
          path: @path,
          name_span: span,
          parameters: [Parameter.new("value", "value", type, nil, :positional)],
          return_type: type,
        )
      end

      private def accessor(arg : Crystal::ASTNode, accessor : Accessor, lazy : Bool) : Nil
        receiver = accessor.receiver
        case arg
        in Crystal::TypeDeclaration
          var = arg.var
          return unless var.is_a?(Crystal::Var)
          type = Syntax::TypeReader.read(arg.declared_type)
          accessor_defs(var, var.name, type, accessor)
          return unless receiver.instance?

          span = span_of(var, var.name.size)
          return unless span

          declared = accessor.bang? || lazy ? nilable(type) : type
          instance_var("@#{var.name}", declared, span, :declared, arg.value, !arg.value.nil?)
        in Crystal::Assign
          target = arg.target
          return unless target.is_a?(Crystal::Var)
          evident = Evident.type(arg.value)
          type = evident.is_a?(Syntax::Type) ? evident : Unrestricted.new
          accessor_defs(target, target.name, type, accessor)
          return unless receiver.instance? && evident.is_a?(Syntax::Type)

          span = span_of(target, target.name.size)
          instance_var("@#{target.name}", evident, span, :assigned) if span
        in Crystal::Var
          accessor_defs(arg, arg.name, Unrestricted.new, accessor)
        in Crystal::Call
          return unless arg.obj.nil? && arg.args.empty?

          accessor_defs(arg, arg.name, Unrestricted.new, accessor)
        in Crystal::SymbolLiteral, Crystal::StringLiteral
          accessor_defs(arg, arg.value, Unrestricted.new, accessor)
        in Crystal::ASTNode then nil
        end
      end

      private def accessor_defs(
        node : Crystal::ASTNode,
        name : String,
        type : Restriction,
        accessor : Accessor,
      ) : Nil
        span = span_of(node, name.size)
        return unless span

        receiver = accessor.receiver
        if accessor.reads?
          reader = "#{name}#{accessor.reader_suffix}"
          none = Array(Parameter).new
          plain = read_of(name, receiver, false)
          if accessor.bang?
            add_def("#{name}?", receiver, span, none, nilable(type), plain)
            add_def(reader, receiver, span, none, type, read_of(name, receiver, true))
          else
            add_def(reader, receiver, span, none, type, plain)
          end
        end
        return unless accessor.writes?

        value = Parameter.new("value", "value", type, nil, :positional)
        add_def("#{name}=", receiver, span, [value], type)
      end

      private def add_def(
        name : String,
        receiver : Receiver,
        span : Document::Span,
        parameters : Array(Parameter),
        return_type : Restriction,
        reads : InstanceVarRead? = nil,
      ) : Nil
        @defs << Def.synthetic(
          name: name,
          owner: @owner,
          path: @path,
          name_span: span,
          receiver: receiver,
          parameters: parameters,
          return_type: return_type,
          visibility: @visibility,
          reads: reads,
        )
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
        @defs << Def.synthetic(
          name: var.name,
          owner: @owner,
          path: @path,
          name_span: span,
          return_type: type,
        )
      end

      private def record_initializer(name : Crystal::Path, fields : Array(Crystal::ASTNode)) : Nil
        span = span_of(name, name.to_s.size)
        return unless span

        parameters = fields.compact_map do |field|
          case field
          in Crystal::TypeDeclaration
            var = field.var
            next unless var.is_a?(Crystal::Var)
            restriction = Syntax::TypeReader.read(field.declared_type)
            Parameter.new(var.name, var.name, restriction, field.value.try(&.to_s), :positional)
          in Crystal::Assign
            target = field.target
            next unless target.is_a?(Crystal::Var)
            evident = Evident.type(field.value)
            type = evident.is_a?(Syntax::Type) ? evident : Unrestricted.new
            Parameter.new(target.name, target.name, type, field.value.to_s, :positional)
          in Crystal::ASTNode then nil
          end
        end
        required = parameters.count(&.default.nil?)
        @defs << Def.synthetic(
          name: Syntax::WellKnown::Initialize.method_name,
          owner: @owner,
          path: @path,
          name_span: span,
          parameters: parameters,
          arity: Arity.new(required, parameters.size - required, false),
        )
      end

      private def record_copies(name : Crystal::Path) : Nil
        span = span_of(name, name.to_s.size)
        return unless span

        add_def("clone", Receiver::Instance, span, Array(Parameter).new, Syntax::SelfType.new)
        changes = Parameter.new("changes", "changes", Unrestricted.new, nil, :double_splat)
        add_def("copy_with", Receiver::Instance, span, [changes], Syntax::SelfType.new)
      end

      private def instance_var(
        name : String,
        type : Syntax::TypeReader::Outcome,
        span : Document::Span,
        origin : Origin,
        expression : Crystal::ASTNode? = nil,
        initialized : Bool = false,
      ) : Nil
        @instance_vars << InstanceVar.build(
          name, @owner, type, @path, span, origin, expression, initialized, @definition
        )
      end

      private def span_of(node : Crystal::ASTNode, size : Int32) : Document::Span?
        location = node.location
        return unless location

        start = Document::Point.from(location)
        span = @text.span(start, start.advance(size))
        span.is_a?(Document::Span) ? span : nil
      end

      private def read_of(name : String, receiver : Receiver, asserted : Bool) : InstanceVarRead?
        InstanceVarRead.new("@#{name}", asserted) if receiver.instance?
      end

      private def nilable(type : Restriction) : Restriction
        case type
        in Syntax::Type                                  then Syntax::Nilable.new(type)
        in Syntax::TypeReader::Unsupported, Unrestricted then type
        end
      end
    end
  end
end
