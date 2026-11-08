require "compiler/crystal/syntax"
require "../document/text"
require "./file"
require "./file_privacy"
require "./accessor"
require "./synthesized"
require "./record_head"
require "./declaration_macros"
require "./macro_hook"
require "./body_traits"
require "./signature"
require "./evident"
require "./macro_text"
require "./macro_body"
require "../crystal_version"
require "../syntax"
require "../syntax/well_known"

module Heucristic
  module Index
    class Collector < Crystal::Visitor
      FLAG_MEMBERS = %w[None All]

      def self.collect(
        path : String,
        text : Document::Text,
        tree : Crystal::ASTNode,
        version : CrystalVersion::Detected,
      ) : File
        collector = new(path, text, version)
        tree.accept(collector)
        collector.file
      end

      def initialize(
        @path : String,
        @text : Document::Text,
        @version : CrystalVersion::Detected,
      ) : Nil
        @privacy = FilePrivacy.new(path)
        @defs = Array(Def).new
        @namespaces = Array(Namespace).new
        @mixins = Array(Mixin).new
        @instance_vars = Array(InstanceVar).new
        @aliases = Array(Alias).new
        @constants = Array(Constant).new
        @macros = Array(MacroDef).new
        @opaque = Array(OpaqueBody).new
        @opaque_blocks = 0
        @flag_enums = Set(UInt64).new
        @definitions = Array(Crystal::Def).new
        @visibilities = Array(Visibility).new
        @owners = Array(Identity).new
      end

      def file : File
        File.new(
          @path, @defs, @namespaces, @mixins, @instance_vars, @aliases, @constants, @macros, @opaque
        )
      end

      def visit(node : Crystal::VisibilityModifier) : Bool
        @privacy.modifier(node, owner)
        applies = modifies_defs?(node.exp)
        @visibilities << (applies ? Visibility.from(node.modifier) : Visibility::Public)
        true
      end

      def end_visit(node : Crystal::VisibilityModifier) : Nil
        @privacy.release
        @visibilities.pop
      end

      def visit(node : Crystal::ClassDef) : Bool
        name = enter(node.name, node)
        with_span(node.name) do |span|
          @namespaces << ClassNamespace.new(
            identity: name,
            path: @path,
            name_span: span,
            kind: node.struct? ? ClassKind::Struct : ClassKind::Class,
            abstract_type: node.abstract?,
            type_vars: node.type_vars || Array(String).new,
            superclass: Restrictions.of(node.superclass),
            splat_index: node.splat_index,
          )
        end
        true
      end

      def visit(node : Crystal::ModuleDef) : Bool
        name = enter(node.name, node)
        with_span(node.name) do |span|
          @namespaces << ModuleNamespace.new(
            identity: name,
            path: @path,
            name_span: span,
            type_vars: node.type_vars || Array(String).new,
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
        name = enter(node.name, node)
        flags = @flag_enums.includes?(node.object_id)
        with_span(node.name) do |span|
          @namespaces << EnumNamespace.new(
            identity: name,
            path: @path,
            name_span: span,
            base_type: Restrictions.of(node.base_type),
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
        name = enter(node.name, node)
        with_span(node.name) do |span|
          @namespaces << LibNamespace.new(identity: name, path: @path, name_span: span)
        end
        true
      end

      def visit(node : Crystal::CStructOrUnionDef) : Bool
        path = Crystal::Path.new([node.name]).at(node.location)
        name = enter(path, node)
        with_span(path) do |span|
          @namespaces << ClassNamespace.new(
            identity: name,
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
        declarations.try { |macros| fields.each { |field| macros.c_field(field) } }
        false
      end

      def visit(node : Crystal::FunDef) : Bool
        name_location = node.name_location
        return false unless name_location

        start = Document::Point.from(name_location)
        span = @text.span(start, start.advance(node.name.size))
        return false unless span.is_a?(Document::Span)

        parameters = node.args.map { |arg| Parameter.from(arg, :positional) }
        @defs << Def.synthetic(
          name: node.name,
          owner: owner,
          path: @path,
          name_span: span,
          receiver: Receiver::Metaclass,
          parameters: parameters,
          return_type: fun_return_type(node),
          arity: Arity.new(node.args.size, 0, node.varargs?),
        )
        false
      end

      def visit(node : Crystal::TypeDef) : Bool
        path = Crystal::Path.new([node.name]).at(node.name_location)
        with_span(path) do |span|
          @aliases << Alias.new(
            identity_for(path, nil), Syntax::TypeReader.read(node.type_spec), @path, span
          )
        end
        false
      end

      def visit(node : Crystal::AnnotationDef) : Bool
        name = enter(node.name, node)
        with_span(node.name) do |span|
          @namespaces << AnnotationNamespace.new(identity: name, path: @path, name_span: span)
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
            identity_for(node.name, node), Syntax::TypeReader.read(node.value), @path, span
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
        return constant(target, node) if target.is_a?(Crystal::Path)
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
        @definitions << node
        true
      end

      def end_visit(node : Crystal::Call) : Nil
        return if node.obj.nil? && Accessor.from_name(node.name)
        return if node.obj.nil? && Synthesized.from_name(node.name)

        @opaque_blocks -= 1 if opaque_block?(node)
      end

      def end_visit(node : Crystal::Def) : Nil
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

      def visit(node : Crystal::MacroExpression | Crystal::MacroFor) : Bool
        mark_opaque
        true
      end

      def visit(node : Crystal::MacroIf) : Bool
        expanded = MacroText.expand(node, @version)
        if expanded.is_a?(MacroText::Undecidable)
          mark_opaque
          return false
        end

        fragment = Syntax.parse_fragment(expanded.text, @path, expanded.at)
        fragment.accept(self) unless fragment.is_a?(Syntax::Broken)
        false
      end

      def visit(node : Crystal::Call) : Bool
        if node.obj.nil? && (accessor = Accessor.from_name(node.name))
          declarations.try(&.accessors(node, accessor))
          return false
        end
        synthesized = node.obj.nil? ? Synthesized.from_name(node.name) : nil
        unless synthesized
          mark_opaque if node.obj.nil?
          @opaque_blocks += 1 if opaque_block?(node)
          return true
        end

        case synthesized
        in .delegate?
          declarations.try(&.delegates(node))
          return false
        in .forward_missing_to? then return record_missing_handler(node)
        in .record?             then nil
        end
        head = RecordHead.of(node)
        return true unless head

        name = head.name
        full = enter(name, node)
        with_span(name) do |span|
          @namespaces << ClassNamespace.new(
            identity: full,
            path: @path,
            name_span: span,
            kind: :struct,
            abstract_type: false,
            type_vars: head.type_vars,
            superclass: Unrestricted.new,
          )
        end
        declarations.try(&.record_declared(name, node.args.skip(1)))
        node.block.try(&.accept(self))
        @owners.pop
        false
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end

      private def declarations : DeclarationMacros?
        namespace = owner
        return if namespace.is_a?(TopLevel)

        DeclarationMacros.new(
          namespace, @path, @text, visibility, @definitions.last?, @defs, @instance_vars
        )
      end

      private def record_missing_handler(node : Crystal::Call) : Bool
        anything = [
          Parameter.new("args", "args", Unrestricted.new, nil, :splat),
          Parameter.new("options", "options", Unrestricted.new, nil, :double_splat),
        ]
        declarations.try(&.forward(node))
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

      private def implicit_member(owner : Identity, member : String, span : Document::Span) : Nil
        type = Syntax::Named.new([owner.name], false)
        value = Constant::ImplicitValue.new
        @constants << Constant.new(owner.child(member), @path, span, value, type, nil)
      end

      private def enum_member(owner : Identity, member : Crystal::ASTNode) : Nil
        return unless member.is_a?(Crystal::Arg)
        location = member.location
        return unless location

        start = Document::Point.from(location)
        span = @text.span(start, start.advance(member.name.size))
        return unless span.is_a?(Document::Span)

        value = member.default_value.try(&.to_s) || Constant::ImplicitValue.new
        type = Syntax::Named.new([owner.name], false)
        @constants << Constant.new(owner.child(member.name), @path, span, value, type, nil)
        @defs << Def.synthetic(
          name: "#{member.name.underscore}?",
          owner: owner,
          path: @path,
          name_span: span,
          return_type: Syntax::Named.of(:bool),
        )
      end

      private def constant(name : Crystal::Path, node : Crystal::Assign) : Bool
        value = node.value
        with_span(name) do |span|
          @constants << Constant.new(
            identity_for(name, node), @path, span, value.to_s, Evident.type(value), value
          )
        end
        false
      end

      private def mark_opaque : Nil
        current = owner
        return unless current.is_a?(Identity) && @definitions.empty?
        return if @opaque.any?(&.owner.==(current))

        @opaque << OpaqueBody.new(current, @path)
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

        @instance_vars << InstanceVar.build(
          name, namespace, type, @path, span, origin, expression, initialized, @definitions.last?
        )
      end

      private def parameter_assignment?(
        target : Crystal::InstanceVar | Crystal::ClassVar,
        value : Crystal::ASTNode,
      ) : Bool
        value.is_a?(Crystal::Var) && "@#{value.name}" == target.name
      end

      private def private_path(node : Crystal::ASTNode) : String?
        @privacy.private_declaration?(node) ? @path : nil
      end

      private def qualify(name : Crystal::Path) : String
        own = name.names.join("::")
        case (namespace = owner)
        in TopLevel then own
        in Identity
          return own if name.global?

          enclosing = enclosing_named(namespace.name, name.names) if name.names.size > 1
          enclosing ? "#{enclosing}::#{name.names[1..].join("::")}" : "#{namespace.name}::#{own}"
        end
      end

      private def enclosing_named(namespace : String, names : Array(String)) : String?
        segments = namespace.split("::")
        head = names[0]
        (segments.size - 1).downto(0) do |index|
          return segments[0..index].join("::") if segments[index] == head
        end
      end

      private def enter(name : Crystal::Path, declaration : Crystal::ASTNode) : Identity
        identity = identity_for(name, declaration)
        @owners << identity
        identity
      end

      private def identity_for(name : Crystal::Path, declaration : Crystal::ASTNode?) : Identity
        @privacy.identity(qualify(name), name, owner, declaration)
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

        identity_for(receiver, nil)
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
          location = target.location
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

      private def visibility : Visibility
        @visibilities.last? || Visibility::Public
      end

      private def modifies_defs?(exp : Crystal::ASTNode) : Bool
        return true if exp.is_a?(Crystal::Def)
        return false unless exp.is_a?(Crystal::Call) && exp.obj.nil?
        return true if Accessor.from_name(exp.name)

        Synthesized.from_name(exp.name).try(&.delegate?) || false
      end

      private def fun_return_type(node : Crystal::FunDef) : Restriction
        returning = node.return_type
        returning ? Restrictions.of(returning) : Syntax::Named.of(:nil)
      end

      private def opaque_block?(node : Crystal::Call) : Bool
        !node.block.nil? && node.obj.nil? && owner.is_a?(Identity) && @definitions.empty?
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
    end
  end
end
