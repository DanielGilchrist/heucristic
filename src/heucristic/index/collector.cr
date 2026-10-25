require "compiler/crystal/syntax"
require "../document/text"
require "./file"
require "./accessor"
require "./synthesized"
require "./record_head"
require "./macro_hook"
require "./body_traits"
require "./signature"
require "./evident"
require "./macro_text"
require "./macro_body"
require "../syntax"
require "../syntax/well_known"

module Heucristic
  module Index
    class Collector < Crystal::Visitor
      FLAG_MEMBERS = %w[None All]

      def self.collect(path : String, text : Document::Text, tree : Crystal::ASTNode) : File
        collector = new(path, text)
        tree.accept(collector)
        collector.file
      end

      def initialize(@path : String, @text : Document::Text) : Nil
        @file_private = nil
        @defs = Array(Def).new
        @namespaces = Array(Namespace).new
        @mixins = Array(Mixin).new
        @instance_vars = Array(InstanceVar).new
        @aliases = Array(Alias).new
        @constants = Array(Constant).new
        @macros = Array(MacroDef).new
        @def_depth = 0
        @opaque_blocks = 0
        @flag_enums = Set(UInt64).new
        @definitions = Array(Crystal::Def).new
        @visibilities = Array(Visibility).new
        @owners = Array(String).new
      end

      def file : File
        File.new(
          @path, @defs, @namespaces, @mixins, @instance_vars, @aliases, @constants, @macros
        )
      end

      def visit(node : Crystal::VisibilityModifier) : Bool
        @file_private = node.exp if node.modifier.private? && owner.is_a?(TopLevel)
        applies = modifies_defs?(node.exp)
        @visibilities << (applies ? Visibility.from(node.modifier) : Visibility::Public)
        true
      end

      def end_visit(node : Crystal::VisibilityModifier) : Nil
        @file_private = nil
        @visibilities.pop
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
            private_path: private_path(node),
            splat_index: node.splat_index,
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
            private_path: private_path(node),
          )
        end
        true
      end

      def visit(node : Crystal::Expressions) : Bool
        node.expressions.each_cons_pair do |before, after|
          next unless after.is_a?(Crystal::EnumDef) && flags_annotation?(before)

          @flag_enums << after.object_id
        end
        true
      end

      def visit(node : Crystal::EnumDef) : Bool
        name = enter(node.name)
        flags = @flag_enums.includes?(node.object_id)
        with_span(node.name) do |span|
          @namespaces << EnumNamespace.new(
            name: name,
            path: @path,
            name_span: span,
            base_type: Restrictions.of(node.base_type),
            private_path: private_path(node),
            flags: flags,
          )
        end
        node.members.each { |member| enum_member(name, member) }
        if flags
          with_span(node.name) do |span|
            FLAG_MEMBERS.each { |member| implicit_member(name, member, span) }
          end
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

      def visit(node : Crystal::CStructOrUnionDef) : Bool
        path = Crystal::Path.new([node.name]).at(node.location)
        name = enter(path)
        with_span(path) do |span|
          @namespaces << ClassNamespace.new(
            name: name,
            path: @path,
            name_span: span,
            kind: ClassKind::Struct,
            abstract_type: false,
            type_vars: Array(String).new,
            superclass: Restrictions.of(nil),
          )
        end
        body = node.body
        fields = body.is_a?(Crystal::Expressions) ? body.expressions : [body]
        fields.each { |field| c_field(field) }
        false
      end

      def visit(node : Crystal::FunDef) : Bool
        name_location = node.name_location
        return false unless name_location

        start = Document::Point.from(name_location)
        span = @text.span(start, start.advance(node.name.size))
        return false unless span.is_a?(Document::Span)

        parameters = node.args.map { |arg| Parameter.from(arg, :positional) }
        @defs << Def.new(
          name: node.name,
          owner: owner,
          receiver: :metaclass,
          path: @path,
          name_span: span,
          arity: Arity.new(node.args.size, 0, node.varargs?),
          parameters: parameters,
          return_type: fun_return_type(node),
          free_vars: Array(String).new,
          yields: false,
        )
        false
      end

      def visit(node : Crystal::TypeDef) : Bool
        path = Crystal::Path.new([node.name]).at(node.name_location)
        with_span(path) do |span|
          @aliases << Alias.new(qualify(path), Syntax::TypeReader.read(node.type_spec), @path, span)
        end
        false
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
               Crystal::AnnotationDef | Crystal::CStructOrUnionDef,
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
            qualify(node.name), Syntax::TypeReader.read(node.value), @path, span, private_path(node)
          )
        end
        false
      end

      def visit(node : Crystal::TypeDeclaration) : Bool
        var = node.var
        return false unless var.is_a?(Crystal::InstanceVar) || var.is_a?(Crystal::ClassVar)

        location = var.location
        return false unless location

        start = Document::Point.from(location)
        span = @text.span(start, start.advance(var.name.size))
        return false unless span.is_a?(Document::Span)

        type = Syntax::TypeReader.read(node.declared_type)
        instance_var(var.name, type, span, :declared, nil, !node.value.nil?)
        false
      end

      def visit(node : Crystal::Assign) : Bool
        target = node.target
        return constant(target, node.value, private_path(node)) if target.is_a?(Crystal::Path)
        return true unless target.is_a?(Crystal::InstanceVar) || target.is_a?(Crystal::ClassVar)

        location = target.location
        return true unless location

        start = Document::Point.from(location)
        span = @text.span(start, start.advance(target.name.size))
        return true unless span.is_a?(Document::Span)

        type = Evident.type(node.value)
        if type.is_a?(Evident::NotEvident)
          return true if parameter_assignment?(target, node.value)

          unsupported = Syntax::TypeReader::Unsupported.new("assignment", node.value.to_s)
          instance_var(target.name, unsupported, span, :assigned, node.value)
        else
          instance_var(target.name, type, span, :assigned)
        end
        true
      end

      def visit(node : Crystal::Def) : Bool
        record_def(node)
        @def_depth += 1
        @definitions << node
        true
      end

      def end_visit(node : Crystal::Call) : Nil
        return if node.obj.nil? && Accessor.from_name(node.name)
        return if node.obj.nil? && Synthesized.from_name(node.name)

        @opaque_blocks -= 1 if opaque_block?(node)
      end

      def end_visit(node : Crystal::Def) : Nil
        @def_depth -= 1
        @definitions.pop
      end

      def visit(node : Crystal::Macro) : Bool
        traits = MacroBody.of(node)
        record_macro(
          node.name,
          node,
          Signature.parameters(node),
          Arity.of(node),
          traits.effect,
          traits.splices_block,
        )
        false
      end

      def visit(node : Crystal::MacroIf) : Bool
        expanded = MacroText.expand(node)
        return false if expanded.is_a?(MacroText::Undecidable)

        fragment = Syntax.parse_fragment(expanded.text, @path, expanded.at)
        fragment.accept(self) unless fragment.is_a?(Syntax::Broken)
        false
      end

      def visit(node : Crystal::Call) : Bool
        if node.obj.nil? && (accessor = Accessor.from_name(node.name))
          return accessors(node, accessor)
        end
        synthesized = node.obj.nil? ? Synthesized.from_name(node.name) : nil
        unless synthesized
          @opaque_blocks += 1 if opaque_block?(node)
          return true
        end

        case synthesized
        in .delegate?           then return delegates(node)
        in .forward_missing_to? then return record_missing_handler(node)
        in .record?             then nil
        end
        head = RecordHead.of(node)
        return true unless head

        name = head.name
        full = enter(name)
        with_span(name) do |span|
          @namespaces << ClassNamespace.new(
            name: full,
            path: @path,
            name_span: span,
            kind: :struct,
            abstract_type: false,
            type_vars: head.type_vars,
            superclass: Unrestricted.new,
            private_path: private_path(node),
          )
        end
        fields = node.args.skip(1)
        fields.each { |field| record_field(field) }
        record_initializer(name, fields)
        record_copies(name)
        node.block.try(&.accept(self))
        @owners.pop
        false
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end

      private def record_missing_handler(node : Crystal::Call) : Bool
        anything = [
          Parameter.new("args", "args", Unrestricted.new, nil, :splat),
          Parameter.new("options", "options", Unrestricted.new, nil, :double_splat),
        ]
        record_macro(
          MacroHook::MethodMissing.macro_name,
          node,
          anything,
          Arity.anything,
          :declaring,
          false,
        )
      end

      private def record_macro(
        name : String,
        node : Crystal::ASTNode,
        parameters : Array(Parameter),
        arity : Arity,
        effect : MacroEffect,
        splices_block : Bool,
      ) : Bool
        location = node.name_location || node.location
        return false unless location

        start = Document::Point.from(location)
        span = @text.span(start, start.advance(name.size))
        return false unless span.is_a?(Document::Span)

        @macros << MacroDef.new(name, owner, @path, span, parameters, arity, effect, splices_block)
        false
      end

      private def flags_annotation?(node : Crystal::ASTNode) : Bool
        node.is_a?(Crystal::Annotation) && node.path.names.last? == "Flags"
      end

      private def implicit_member(owner : String, member : String, span : Document::Span) : Nil
        type = Syntax::Named.new([owner], false)
        value = Constant::ImplicitValue.new
        @constants << Constant.new("#{owner}::#{member}", @path, span, value, type, nil)
      end

      private def enum_member(owner : String, member : Crystal::ASTNode) : Nil
        return unless member.is_a?(Crystal::Arg)
        location = member.location
        return unless location

        start = Document::Point.from(location)
        span = @text.span(start, start.advance(member.name.size))
        return unless span.is_a?(Document::Span)

        value = member.default_value.try(&.to_s) || Constant::ImplicitValue.new
        type = Syntax::Named.new([owner], false)
        @constants << Constant.new("#{owner}::#{member.name}", @path, span, value, type, nil)
        @defs << Def.new(
          name: "#{member.name.underscore}?",
          owner: owner,
          receiver: :instance,
          path: @path,
          name_span: span,
          arity: Arity.new(0, 0, false),
          parameters: Array(Parameter).new,
          return_type: Syntax::Named.of(:bool),
          free_vars: Array(String).new,
          yields: false,
        )
      end

      private def record_copies(name : Crystal::Path) : Nil
        span = span_of(name, name.to_s.size)
        return unless span

        add_def("clone", :instance, span, Array(Parameter).new, Syntax::SelfType.new)
        changes = Parameter.new("changes", "changes", Unrestricted.new, nil, :double_splat)
        add_def("copy_with", :instance, span, [changes], Syntax::SelfType.new)
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
        @defs << Def.new(
          name: Syntax::WellKnown::Initialize.method_name,
          owner: owner,
          receiver: :instance,
          path: @path,
          name_span: span,
          arity: Arity.new(required, parameters.size - required, false),
          parameters: parameters,
          return_type: Unrestricted.new,
          free_vars: Array(String).new,
          yields: false,
        )
      end

      private def constant(
        name : Crystal::Path,
        value : Crystal::ASTNode,
        private_path : String?,
      ) : Bool
        with_span(name) do |span|
          @constants << Constant.new(
            qualify(name), @path, span, value.to_s, Evident.type(value), value, private_path
          )
        end
        false
      end

      private def owner : Owner
        @owners.last? || TopLevel.new
      end

      private def mixin(kind : MixinKind, target : Crystal::ASTNode) : Bool
        @mixins << Mixin.new(owner, kind, Syntax::TypeReader.read(target), @path)
        false
      end

      private def instance_var(
        name : String,
        type : Syntax::TypeReader::Outcome,
        span : Document::Span,
        origin : Origin,
        expression : Crystal::ASTNode? = nil,
        initialized : Bool = false,
      ) : Nil
        namespace = owner
        return if namespace.is_a?(TopLevel)

        in_def = @def_depth > 0
        initialized ||= origin.assigned? && !in_def
        @instance_vars << InstanceVar.new(
          name, namespace, type, @path, span, origin, expression, initialized, in_def,
          @definitions.last?,
        )
      end

      private def parameter_assignment?(
        target : Crystal::InstanceVar | Crystal::ClassVar,
        value : Crystal::ASTNode,
      ) : Bool
        value.is_a?(Crystal::Var) && "@#{value.name}" == target.name
      end

      private def private_path(node : Crystal::ASTNode) : String?
        @file_private.try(&.same?(node)) ? @path : nil
      end

      private def qualify(name : Crystal::Path) : String
        own = name.names.join("::")
        case (namespace = owner)
        in TopLevel then own
        in String
          return own if name.global?

          enclosing = enclosing_named(namespace, name.names) if name.names.size > 1
          enclosing ? "#{enclosing}::#{name.names[1..].join("::")}" : "#{namespace}::#{own}"
        end
      end

      private def enclosing_named(namespace : String, names : Array(String)) : String?
        segments = namespace.split("::")
        head = names[0]
        (segments.size - 1).downto(0) do |index|
          return segments[0..index].join("::") if segments[index] == head
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

      private def def_owner(node : Crystal::Def) : Owner
        receiver = node.receiver
        return owner unless receiver.is_a?(Crystal::Path)

        qualify(receiver)
      end

      private def yielding_without_restriction?(node : Crystal::Def) : Bool
        yields = !node.block_arity.nil? || !node.block_arg.nil?
        return false unless yields

        restriction = node.block_arg.try(&.restriction)
        restriction.nil? || (restriction.is_a?(Crystal::ProcNotation) && restriction.inputs.nil?)
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
          block_arg = node.block_arg
          if parameter.nil? && block_arg && block_arg.name == value.name
            parameter = block_arg
          end
          next unless parameter
          location = parameter.location
          next unless location

          start = Document::Point.from(location)
          span = @text.span(start, start.advance(target.name.size))
          next unless span.is_a?(Document::Span)

          if (restriction = parameter.restriction)
            initializer = Syntax::WellKnown::Initialize.named?(node.name)
            origin = initializer ? Origin::Declared : Origin::Assigned
            instance_var(target.name, Syntax::TypeReader.read(restriction), span, origin)
            next
          end

          default = parameter.default_value
          evident = default ? Evident.type(default) : Evident::NotEvident.new
          if evident.is_a?(Syntax::Type)
            instance_var(target.name, evident, span, :assigned)
          else
            unsupported = Syntax::TypeReader::Unsupported.new("parameter", parameter.name)
            instance_var(target.name, unsupported, span, :assigned)
          end
        end
      end

      private def delegates(node : Crystal::Call) : Bool
        return false if owner.is_a?(TopLevel)
        target = node.named_args.try(&.find(&.name.==("to"))).try(&.value)
        return false unless target

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

          @defs << Def.new(
            name: name,
            owner: owner,
            receiver: :instance,
            path: @path,
            name_span: span,
            arity: Arity.new(0, 0, true),
            parameters: [Parameter.new("args", "args", Unrestricted.new, nil, :splat)],
            return_type: Unrestricted.new,
            free_vars: Array(String).new,
            yields: false,
            forwards_to: target,
          )
        end
        false
      end

      private def accessors(node : Crystal::Call, accessor : Accessor) : Bool
        return false if owner.is_a?(TopLevel)

        lazy = !node.block.nil?
        node.args.each { |arg| accessor(arg, accessor, lazy) }
        false
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

          instance_var("@#{target.name}", evident, span_of(target, target.name.size), :assigned)
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
        @defs << Def.new(
          name: name,
          owner: owner,
          receiver: receiver,
          path: @path,
          name_span: span,
          arity: Arity.new(parameters.size, 0, false),
          parameters: parameters,
          return_type: return_type,
          free_vars: Array(String).new,
          yields: false,
          visibility: visibility,
          reads: reads,
        )
      end

      private def visibility : Visibility
        @visibilities.last? || Visibility::Public
      end

      private def modifies_defs?(exp : Crystal::ASTNode) : Bool
        return true if exp.is_a?(Crystal::Def)
        return false unless exp.is_a?(Crystal::Call) && exp.obj.nil?
        return true if Accessor.from_name(exp.name)

        Synthesized.from_name(exp.name).try(&.delegate?) || false
      end

      private def span_of(node : Crystal::ASTNode, size : Int32) : Document::Span?
        location = node.location
        return unless location

        start = Document::Point.from(location)
        span = @text.span(start, start.advance(size))
        span.is_a?(Document::Span) ? span : nil
      end

      private def instance_var(
        name : String,
        type : Syntax::TypeReader::Outcome,
        span : Document::Span?,
        origin : Origin,
      ) : Nil
        instance_var(name, type, span, origin) if span
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

      private def fun_return_type(node : Crystal::FunDef) : Restriction
        returning = node.return_type
        returning ? Restrictions.of(returning) : Syntax::Named.of(:nil)
      end

      private def c_field(field : Crystal::ASTNode) : Nil
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
        @defs << Def.new(
          name: "#{var.name}=",
          owner: owner,
          receiver: :instance,
          path: @path,
          name_span: span,
          arity: Arity.new(1, 0, false),
          parameters: [Parameter.new("value", "value", type, nil, :positional)],
          return_type: type,
          free_vars: Array(String).new,
          yields: false,
        )
      end

      private def opaque_block?(node : Crystal::Call) : Bool
        !node.block.nil? && node.obj.nil? && owner.is_a?(String) && @def_depth == 0
      end

      private def record_def(node : Crystal::Def) : Nil
        return if @opaque_blocks > 0

        record_ivar_parameters(node)
        name_location = node.name_location
        return unless name_location

        start = Document::Point.from(name_location)
        span = @text.span(start, start.advance(node.name.size))
        return unless span.is_a?(Document::Span)

        traits = BodyTraits.of(node)
        @defs << Def.new(
          name: node.name,
          owner: def_owner(node),
          receiver: node.receiver ? Receiver::Metaclass : Receiver::Instance,
          path: @path,
          name_span: span,
          arity: Arity.of(node),
          parameters: Signature.parameters(node),
          return_type: Restrictions.of(node.return_type),
          free_vars: node.free_vars || Array(String).new,
          yields: !node.block_arity.nil? || !node.block_arg.nil?,
          node: yielding_without_restriction?(node) || traits.with_yield ? node : nil,
          with_yield: traits.with_yield,
          macro_body: traits.macro_body,
          abstract_def: node.abstract?,
          visibility: visibility,
          private_path: private_path(node),
          exit_call: traits.exit_call,
          reads: read_instance_var(node),
        )
      end

      private def read_instance_var(node : Crystal::Def) : InstanceVarRead?
        return if node.receiver || !node.args.empty? || node.block_arity || node.return_type

        body = node.body
        InstanceVarRead.new(body.name, false) if body.is_a?(Crystal::InstanceVar)
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
