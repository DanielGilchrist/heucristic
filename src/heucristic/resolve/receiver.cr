require "compiler/crystal/syntax"
require "../index/workspace"
require "../index/shims"
require "../index/evident"
require "../syntax/target"
require "../syntax/type_reader"
require "./types"
require "./methods"
require "./unify"
require "./render"
require "./local_declarations"
require "./local_assignments"
require "./rescue_variables"
require "./flow"
require "../syntax/yield_sites"

module Heucristic
  module Resolve
    class Receiver
      DEPTH_LIMIT = 48

      record Site,
        block : Crystal::Block?,
        context : Syntax::Context,
        locals : Array(Binding),
        visiting : Array(String),
        named : Array(Binding) = Array(Binding).new,
        block_arg : Crystal::ASTNode? = nil do
        NONE = new(
          nil,
          Syntax::Context.new(Array(String).new, Array(String).new, nil),
          Array(Binding).new,
          Array(String).new,
        )
      end

      FALSEY = {"Nil", "Bool", "Pointer"}

      def initialize(
        @workspace : Index::Workspace,
        @shims : Index::Shims,
        @types : Types,
        @methods : Methods,
      ) : Nil
        @depth = 0
      end

      def result_of(
        call : Crystal::Call,
        context : Syntax::Context,
        locals : Array(Binding) = Array(Binding).new,
        visiting : Array(String) = Array(String).new,
      ) : Resolution
        receiver = of_call(call, context, locals, visiting)
        return receiver if receiver.is_a?(Unknown)

        shape = shape_of(call, context, locals, visiting)
        site = Site.new(
          call.block, context, locals, visiting, shape.named_arguments, call.block_arg
        )
        if call.obj.nil? && call.name == "super"
          return super_result(call, receiver, shape, site)
        end

        result_of(receiver, shape, site)
      end

      def shape_of(
        call : Crystal::Call,
        context : Syntax::Context,
        locals : Array(Binding) = Array(Binding).new,
        visiting : Array(String) = Array(String).new,
      ) : Methods::Call
        arguments = Array(Resolution).new(call.args.size)
        call.args.each { |argument| arguments << type_of(argument, context, visiting, locals) }
        named = call.named_args.try(&.map(&.name)) || Array(String).new
        named_arguments = Array(Binding).new
        call.named_args.try &.each do |argument|
          value = type_of(argument.value, context, visiting, locals)
          named_arguments << Binding.new(argument.name, value)
        end
        Methods::Call.new(
          call.name, call.args.size, blocky?(call), arguments, named, named_arguments
        )
      end

      def result_of(receiver : Resolved, call : Methods::Call) : Resolution
        result_of(receiver, call, Site::NONE)
      end

      def result_of(receiver : Resolved, call : Methods::Call, site : Site) : Resolution
        if receiver.is_a?(UnionRef)
          members = receiver.members.map do |member|
            member.is_a?(Unknown) ? member : result_of(member, call, site)
          end
          return union(members)
        end

        defs = @methods.lookup(receiver, call)
        return Unknown.new(:unresolved_name, "no `#{call.name}` on #{receiver}") if defs.empty?

        results = Array(Resolution).new(defs.size)
        defs.each { |entry| results << return_type(entry, receiver, call.arguments, site) }
        distinct = results.uniq
        return distinct[0] if distinct.size == 1

        Unknown.new(:ambiguous, "#{defs.size} overloads of `#{call.name}` do not agree on a type")
      end

      def of_call(
        call : Crystal::Call,
        context : Syntax::Context,
        locals : Array(Binding) = Array(Binding).new,
        visiting : Array(String) = Array(String).new,
      ) : Resolution
        receiver = call.obj
        return implicit_self(context) unless receiver

        type_of(receiver, context, visiting, locals)
      end

      def variable(name : String, context : Syntax::Context) : Resolution
        variable(name, context, Array(String).new, Array(Binding).new)
      end

      def instance_var(name : String, context : Syntax::Context) : Resolution
        instance_var(name, context, Array(String).new)
      end

      def return_type(
        entry : Index::Def,
        receiver : Resolved,
        arguments : Array(Resolution) = Array(Resolution).new,
        site : Site = Site::NONE,
      ) : Resolution
        if entry.name == "initialize" && receiver.is_a?(MetaRef)
          return receiver.of
        end
        if entry.qualified == "Object#class"
          return MetaRef.new(receiver) if receiver.is_a?(TypeRef)
          return receiver if receiver.is_a?(MetaRef)
        end
        if entry.qualified == "Array#compact" && receiver.is_a?(TypeRef)
          return compacted(receiver)
        end
        if entry.qualified == "Proc#call" && receiver.is_a?(TypeRef)
          return receiver.arguments.last? || Unknown.new(:unsupported, "a proc without a signature")
        end

        case (restriction = entry.return_type)
        in Index::Unrestricted
          shim = @shims.find(entry)
          return return_type(shim.entry, receiver, arguments, site) if shim
          if (target = entry.forwards_to)
            return forwarded(entry, target, arguments, site)
          end

          Unknown.new(:no_annotation, "#{entry.qualified} has no return type restriction")
        in Syntax::TypeReader::Unsupported
          Unknown.new(:unsupported, restriction.source)
        in Syntax::Type
          scope = return_scope(entry, receiver, arguments, site)
          return scope if scope.is_a?(Unknown)

          @types.resolve(restriction, scope)
        end
      end

      def signature(
        entry : Index::Def,
        receiver : Resolved,
        arguments : Array(Resolution),
        site : Site,
      ) : String
        scope = return_scope(entry, receiver, arguments, site)
        return entry.signature if scope.is_a?(Unknown)

        parameters = entry.parameters.map do |parameter|
          restriction = parameter.restriction
          text = restriction.is_a?(Syntax::Type) ? Render.type(restriction, scope, @types) : nil
          parameter.rendered(text)
        end
        returning = return_type(entry, receiver, arguments, site)
        receiver_name = entry.receiver.metaclass? ? "self" : nil
        Index::Signature.render(receiver_name, entry.name, parameters) do |io|
          io << " : " << returning if returning.is_a?(Resolved)
        end
      end

      def type_of(entry : Index::Constant) : Resolution
        constant_type(entry, entry.name, Array(String).new)
      end

      private def case_subject(
        context : Syntax::Context,
        visiting : Array(String),
        locals : Array(Binding),
      ) : Resolution
        enclosing = context.ancestors.reverse_each.find { |node| node.is_a?(Crystal::Case) }
        subject = enclosing.is_a?(Crystal::Case) ? enclosing.cond : nil
        unless subject
          return Unknown.new(:unsupported, "an implicit object outside a case")
        end

        type_of(subject, context, visiting, locals)
      end

      private def super_result(
        call : Crystal::Call,
        receiver : Resolved,
        shape : Methods::Call,
        site : Site,
      ) : Resolution
        definition = site.context.def_node
        owner = site.context.owner
        unless definition && owner.is_a?(String)
          return Unknown.new(:no_annotation, "super outside a method")
        end

        return TypeRef.new("Nil", Array(Resolution).new) if definition.name == "initialize"

        arity = call.has_parentheses? ? shape.arity : definition.args.size
        parent_call = Methods::Call.new(
          definition.name, arity, shape.block, shape.arguments, shape.named
        )
        defs = @methods.lookup_super(receiver, owner, parent_call)
        if defs.empty?
          return Unknown.new(:unresolved_name, "no `#{definition.name}` above #{owner}")
        end

        results = Array(Resolution).new(defs.size)
        defs.each { |entry| results << return_type(entry, receiver, shape.arguments, site) }
        distinct = results.uniq
        return distinct[0] if distinct.size == 1

        Unknown.new(:ambiguous, "#{defs.size} overloads of `super` do not agree on a type")
      end

      private def blocky?(call : Crystal::Call) : Bool
        !call.block.nil? || !call.block_arg.nil?
      end

      private def instance_var(
        name : String,
        context : Syntax::Context,
        visiting : Array(String),
      ) : Resolution
        owner = context.owner
        if owner.is_a?(Index::TopLevel)
          return Unknown.new(:no_annotation, "#{name} outside any type")
        end

        levels = [owner]
        chain = @types.ancestors(owner)
        levels.concat(chain) unless chain.is_a?(Unknown)
        levels.each do |level|
          entries = @workspace.instance_vars_of(level).select(&.name.==(name))
          next if entries.empty?

          declared = entries.select(&.origin.declared?)
          sources = declared.empty? ? entries : declared
          scope = ivar_scope(owner, level)
          return scope if scope.is_a?(Unknown)

          return union(sources.map { |entry| declared(entry.type, scope) })
        end

        from_includers = includers_instance_var(name, owner, visiting)
        return from_includers if from_includers

        Unknown.new(
          :no_annotation, "#{name} is never declared or assigned an evident type in #{owner}"
        )
      end

      private def includers_instance_var(
        name : String,
        owner : String,
        visiting : Array(String),
      ) : Resolution?
        return unless @workspace.namespaces(owner).any?(Index::ModuleNamespace)
        return if visiting.includes?(owner)

        found = Array(Resolution).new
        @workspace.each_mixin do |mixin|
          next unless mixin.kind.include?
          target = mixin.target
          next unless target.is_a?(Syntax::Type)

          resolved = @types.resolve_lexically(target, Scope.of(mixin.owner))
          next unless resolved.is_a?(TypeRef) && resolved.name == owner

          context = Syntax::Context.new([mixin.owner], Array(String).new, nil)
          resolution = instance_var(name, context, visiting + [owner])
          found << resolution unless resolution.is_a?(Unknown)
        end
        return if found.empty?

        union(found)
      end

      private def ivar_scope(owner : String, level : String) : Scope | Unknown
        return Scope.of(owner) if level == owner

        this = TypeRef.new(owner, Array(Resolution).new)
        bindings = @types.bindings(this, level)
        return bindings if bindings.is_a?(Unknown)

        Scope.new(level, @types.type_vars_of(level), bindings)
      end

      private def type_of(
        node : Crystal::ASTNode,
        context : Syntax::Context,
        visiting : Array(String),
        locals : Array(Binding),
      ) : Resolution
        if @depth >= DEPTH_LIMIT
          return Unknown.new(:too_deep, "typing `#{node}` needs more than #{DEPTH_LIMIT} steps")
        end

        @depth += 1
        begin
          typed(node, context, visiting, locals)
        ensure
          @depth -= 1
        end
      end

      private def typed(
        node : Crystal::ASTNode,
        context : Syntax::Context,
        visiting : Array(String),
        locals : Array(Binding),
      ) : Resolution
        return constant(node, context, visiting) if node.is_a?(Crystal::Path)
        evident = Index::Evident.type(node)
        return declared(evident, scope(context)) if evident.is_a?(Syntax::Type)

        case node
        when Crystal::Var         then variable(node.name, context, visiting, locals)
        when Crystal::InstanceVar then instance_var(node.name, context)
        when Crystal::Call        then result_of(node, context, locals, visiting)
        when Crystal::Path        then constant(node, context, visiting)
        when Crystal::ImplicitObj then case_subject(context, visiting, locals)
        when Crystal::If, Crystal::Unless
          branches = Array(Resolution).new(2)
          branches << type_of(node.then, context.inside(node, node.then), visiting, locals)
          branches << type_of(node.else, context.inside(node, node.else), visiting, locals)
          union(branches)
        when Crystal::Return, Crystal::Break then TypeRef.new("NoReturn", Array(Resolution).new)
        when Crystal::Or
          left = type_of(node.left, context.inside(node, node.left), visiting, locals)
          right = type_of(node.right, context.inside(node, node.right), visiting, locals)
          union([truthy(left, true), right] of Resolution)
        when Crystal::And
          left = type_of(node.left, context.inside(node, node.left), visiting, locals)
          right = type_of(node.right, context.inside(node, node.right), visiting, locals)
          union([truthy(left, false), right] of Resolution)
        when Crystal::Next
          value = node.exp
          return TypeRef.new("Nil", Array(Resolution).new) unless value

          type_of(value, context, visiting, locals)
        when Crystal::ArrayLiteral
          elements(node.elements, context, visiting, locals) do |inner|
            TypeRef.new("Array", [inner] of Resolution)
          end
        when Crystal::TupleLiteral
          members = Array(Resolution).new(node.elements.size)
          node.elements.each { |element| members << type_of(element, context, visiting, locals) }
          members.find(&.is_a?(Unknown)) || TypeRef.new("Tuple", members)
        when Crystal::Nop then TypeRef.new("Nil", Array(Resolution).new)
        when Crystal::Expressions
          last = node.expressions.last?
          return TypeRef.new("Nil", Array(Resolution).new) unless last

          type_of(last, context.inside(node, last), visiting, locals)
        else
          Unknown.new(:inference_needed, "the type of `#{node}` is not written in the source")
        end
      end

      private def variable(
        name : String,
        context : Syntax::Context,
        visiting : Array(String),
        locals : Array(Binding),
      ) : Resolution
        return implicit_self(context) if name == "self"
        if (local = locals.find(&.name.==(name)))
          return narrow(local.value, name, context, visiting, locals)
        end
        return Unknown.new(:cycle, name) if visiting.includes?(name)

        narrow(declared_variable(name, context, visiting, locals), name, context, visiting, locals)
      end

      private def narrow(
        base : Resolution,
        name : String,
        context : Syntax::Context,
        visiting : Array(String),
        locals : Array(Binding),
      ) : Resolution
        Flow.steps(name, context.ancestors).reduce(base) do |current, step|
          case step
          in Flow::Assigned then type_of(step.value, context, visiting + [name], locals)
          in Flow::Truthy   then truthy(current, step.positive)
          in Flow::IsA      then narrow_is_a(current, step.types, step.positive, context)
          end
        end
      end

      private def truthy(current : Resolution, positive : Bool) : Resolution
        return current if current.is_a?(Unknown)

        members = current.is_a?(UnionRef) ? current.members : [current] of Resolution
        kept = members.select do |member|
          next true if member.is_a?(Unknown)
          falsey = member.is_a?(TypeRef) && FALSEY.includes?(member.name)
          positive ? !(member.is_a?(TypeRef) && member.name == "Nil") : falsey
        end
        return current if kept.empty?

        kept.size == 1 ? kept[0] : UnionRef.new(kept)
      end

      private def narrow_is_a(
        current : Resolution,
        types : Array(Crystal::ASTNode),
        positive : Bool,
        context : Syntax::Context,
      ) : Resolution
        targets = Array(TypeRef).new
        types.each do |type|
          resolved = declared(Syntax::TypeReader.read(type), scope(context))
          return current unless resolved.is_a?(TypeRef)
          targets << resolved
        end

        if current.is_a?(Unknown)
          return current unless positive
          return targets[0] if targets.size == 1

          widened = Array(Resolution).new(targets.size)
          targets.each { |target| widened << target }
          return UnionRef.new(widened)
        end

        members = current.is_a?(UnionRef) ? current.members : [current] of Resolution
        kept = Array(Resolution).new
        members.each do |member|
          unless member.is_a?(TypeRef)
            kept << member
            next
          end
          matched = targets.any? { |target| covers?(target, member) }
          if positive
            kept << member if matched
            targets.each { |target| kept << target if !matched && covers?(member, target) }
          else
            kept << member unless matched
          end
        end
        return current if kept.empty?

        kept.size == 1 ? kept[0] : UnionRef.new(kept)
      end

      private def covers?(ancestor : TypeRef, descendant : TypeRef) : Bool
        return true if ancestor.name == descendant.name

        chain = @types.ancestors(descendant.name)
        !chain.is_a?(Unknown) && chain.includes?(ancestor.name)
      end

      private def declared_variable(
        name : String,
        context : Syntax::Context,
        visiting : Array(String),
        locals : Array(Binding),
      ) : Resolution
        definition = context.def_node
        return Unknown.new(:no_annotation, "#{name} is outside any method") unless definition

        if (parameter = definition.args.find(&.name.==(name)))
          restriction = parameter.restriction
          unless restriction
            return Unknown.new(:no_annotation, "parameter #{name} has no type restriction")
          end
          typed = declared(Syntax::TypeReader.read(restriction), scope(context))
          return typed if typed.is_a?(Unknown)
          return typed unless definition.splat_index == definition.args.index(parameter)

          return TypeRef.new("Tuple", [typed] of Resolution)
        end

        if (block_arg = definition.block_arg) && block_arg.name == name
          restriction = block_arg.restriction
          unless restriction
            return Unknown.new(:no_annotation, "block parameter #{name} has no type restriction")
          end

          return declared(Syntax::TypeReader.read(restriction), scope(context))
        end

        if (declaration = LocalDeclarations.find(definition.body, name))
          return declared(Syntax::TypeReader.read(declaration.declared_type), scope(context))
        end

        return Unknown.new(:cycle, name) if visiting.includes?(name)

        if (from_block = block_parameter(name, context, locals, visiting + [name]))
          return from_block
        end

        rescued = RescueVariables.find(definition.body, name)
        return rescued_type(rescued, context) if rescued

        assignments = LocalAssignments.find(definition.body, name)
        if assignments.empty?
          return Unknown.new(
            :no_annotation, "#{name} is not a parameter and is never assigned here"
          )
        end

        assigned = Array(Resolution).new(assignments.size)
        assignments.each { |value| assigned << type_of(value, context, visiting + [name], locals) }
        union(assigned)
      end

      private def elements(
        nodes : Array(Crystal::ASTNode),
        context : Syntax::Context,
        visiting : Array(String),
        locals : Array(Binding),
        & : Resolution -> Resolution
      ) : Resolution
        if nodes.empty?
          return Unknown.new(:no_annotation, "an empty literal needs `of T` to state its type")
        end

        typed = Array(Resolution).new(nodes.size)
        nodes.each { |element| typed << type_of(element, context, visiting, locals) }
        inner = union(typed)
        return inner if inner.is_a?(Unknown)

        yield inner
      end

      private def rescued_type(rescued : Crystal::Rescue, context : Syntax::Context) : Resolution
        types = rescued.types
        return TypeRef.new("Exception", Array(Resolution).new) unless types

        union(types.map { |type| declared(Syntax::TypeReader.read(type), scope(context)) })
      end

      private def union(resolutions : Array(Resolution)) : Resolution
        members = Array(Resolution).new
        resolutions.each do |resolution|
          return resolution if resolution.is_a?(Unknown)
          next if resolution.is_a?(TypeRef) && resolution.name == "NoReturn"
          if resolution.is_a?(UnionRef)
            resolution.members.each { |inner| members << inner unless members.includes?(inner) }
          else
            members << resolution unless members.includes?(resolution)
          end
        end
        return TypeRef.new("NoReturn", Array(Resolution).new) if members.empty?

        members.size == 1 ? members[0] : UnionRef.new(members)
      end

      private def implicit_self(context : Syntax::Context) : Resolution
        owner = context.owner
        return Unknown.new(:top_level, "no enclosing type") if owner.is_a?(Index::TopLevel)

        this = TypeRef.new(owner, Array(Resolution).new)
        definition = context.def_node
        definition && definition.receiver ? MetaRef.new(this) : this
      end

      private def compacted(receiver : TypeRef) : Resolution
        element = receiver.arguments[0]?
        return receiver unless element.is_a?(UnionRef)

        kept = element.members.reject { |member| member.is_a?(TypeRef) && member.name == "Nil" }
        TypeRef.new("Array", [union(kept)] of Resolution)
      end

      private def forwarded(
        entry : Index::Def,
        target : Crystal::ASTNode,
        arguments : Array(Resolution),
        site : Site,
      ) : Resolution
        owner = entry.owner
        enclosing = owner.is_a?(String) ? [owner] : Array(String).new
        context = Syntax::Context.new(enclosing, Array(String).new, nil)
        return Unknown.new(:cycle, entry.qualified) if site.visiting.includes?(entry.qualified)

        visiting = site.visiting + [entry.qualified]
        delegate = type_of(target, context, visiting, Array(Binding).new)
        return delegate if delegate.is_a?(Unknown)

        shape = Methods::Call.new(entry.name, arguments.size, !site.block.nil?, arguments)
        result_of(delegate, shape, Site.new(site.block, site.context, site.locals, visiting))
      end

      private def return_scope(
        entry : Index::Def,
        receiver : Resolved,
        arguments : Array(Resolution),
        site : Site,
      ) : Scope | Unknown
        owner = entry.owner
        bindings = Array(Binding).new
        type_vars = entry.free_vars.dup
        free_vars = entry.free_vars.dup
        unless owner.is_a?(Index::TopLevel)
          instance = receiver.is_a?(MetaRef) ? receiver.of : receiver
          inherited = instance.is_a?(TypeRef) ? @types.bindings(instance, owner) : bindings
          if inherited.is_a?(Unknown)
            return inherited unless receiver.is_a?(MetaRef) && @types.type_vars_of(owner).empty?

            inherited = Array(Binding).new
          end
          bindings = inherited.dup
          bindings << Binding.new("self", instance)
          owner_vars = @types.type_vars_of(owner)
          type_vars = owner_vars + type_vars
          if receiver.is_a?(MetaRef)
            free_vars.concat(owner_vars.reject { |name| bindings.any?(&.name.==(name)) })
          end
        end

        scope = Scope.new(owner, type_vars, bindings)
        bind_arguments(entry, arguments, free_vars, bindings, scope)
        bind_named(entry, site.named, free_vars, bindings, scope)
        bind_block(entry, site, free_vars, bindings, scope)
        entry.free_vars.each do |free_var|
          next if bindings.any?(&.name.==(free_var))

          bindings << Binding.new(
            free_var,
            Unknown.new(
              :free_variable,
              "#{free_var} is not fixed by the arguments or block of #{entry.qualified}",
            ),
          )
        end
        scope
      end

      private def constant(
        path : Crystal::Path,
        context : Syntax::Context,
        visiting : Array(String),
      ) : Resolution
        scope = scope(context)
        located = @types.locate_any(Syntax::Named.new(path.names, path.global?), scope)
        return located if located.is_a?(Unknown)

        constants = @workspace.constants(located)
        if constants.empty?
          resolved = @types.resolve(Syntax::Named.new(path.names, path.global?), scope)
          return metaclass_of(resolved)
        end
        return Unknown.new(:cycle, located) if visiting.includes?(located)

        union(constants.map { |entry| constant_type(entry, located, visiting + [located]) })
      end

      private def metaclass_of(resolved : Resolution) : Resolution
        case resolved
        in TypeRef then MetaRef.new(resolved)
        in UnionRef
          members = Array(Resolution).new(resolved.members.size)
          resolved.members.each { |member| members << metaclass_of(member) }
          UnionRef.new(members)
        in MetaRef, Unknown then resolved
        end
      end

      private def constant_type(
        entry : Index::Constant,
        name : String,
        visiting : Array(String),
      ) : Resolution
        owner = name.rpartition("::")[0]
        owner_scope = owner.empty? ? Scope::TOP : Scope.of(owner)
        type = entry.type
        return @types.resolve(type, owner_scope) if type.is_a?(Syntax::Type)

        expression = entry.expression
        unless expression
          return Unknown.new(:no_annotation, "#{name} has no value to type")
        end

        enclosing = owner.empty? ? Array(String).new : [owner]
        context = Syntax::Context.new(enclosing, Array(String).new, nil)
        type_of(expression, context, visiting, Array(Binding).new)
      end

      private def block_parameter(
        name : String,
        context : Syntax::Context,
        locals : Array(Binding),
        visiting : Array(String),
      ) : Resolution?
        context.blocks.reverse_each do |call|
          block = call.block
          next unless block
          index = block.args.index(&.name.==(name))
          unpacked = index ? nil : unpacked_position(block, name)
          index ||= unpacked.try(&.[0])
          next unless index

          enclosing_blocks = context.blocks[0...context.blocks.index!(call)]
          upto = context.ancestors.index(&.same?(call))
          outer_ancestors = upto ? context.ancestors[0..upto] : Array(Crystal::ASTNode).new
          outer = Syntax::Context.new(
            context.enclosing,
            context.type_vars,
            context.def_node,
            enclosing_blocks,
            outer_ancestors,
          )
          receiver = of_call(call, outer, locals, visiting)
          return receiver if receiver.is_a?(Unknown)

          shape = shape_of(call, outer, locals, visiting)
          input = block_inputs(receiver, shape, index, block.args.size)
          return input unless unpacked

          return tuple_element(input, unpacked[1], name)
        end
        nil
      end

      private def unpacked_position(block : Crystal::Block, name : String) : Tuple(Int32, Int32)?
        block.unpacks.try &.each do |index, expressions|
          position = expressions.expressions.index do |var|
            var.is_a?(Crystal::Var) && var.name == name
          end
          return {index, position} if position
        end
        nil
      end

      private def tuple_element(input : Resolution, position : Int32, name : String) : Resolution
        return input if input.is_a?(Unknown)
        unless input.is_a?(TypeRef)
          return Unknown.new(:unsupported, "#{name} unpacks a #{input}, which is not indexable")
        end
        if input.name == "Tuple"
          element = input.arguments[position]?
          return element || Unknown.new(:unsupported, "#{name} unpacks past the tuple's size")
        end

        chain = @types.ancestors(input.name)
        inherits = !chain.is_a?(Unknown) && chain.includes?("Indexable")
        indexable = input.name == "Indexable" || inherits
        unless indexable
          return Unknown.new(:unsupported, "#{name} unpacks a #{input}, which is not indexable")
        end

        element = input.arguments[0]?
        element || Unknown.new(:unsupported, "#{name} unpacks #{input} with no element type")
      end

      private def block_inputs(
        receiver : Resolved,
        shape : Methods::Call,
        index : Int32,
        parameters : Int32,
      ) : Resolution
        if receiver.is_a?(UnionRef)
          per_member = Array(Resolution).new(receiver.members.size)
          receiver.members.each do |member|
            per_member << if member.is_a?(Unknown)
              member
            else
              block_inputs(member, shape, index, parameters)
            end
          end
          return union(per_member)
        end

        defs = @methods.lookup(receiver, shape)
        return Unknown.new(:unresolved_name, "no `#{shape.name}` on #{receiver}") if defs.empty?

        inputs = Array(Resolution).new(defs.size)
        defs.each do |entry|
          inputs << block_input(entry, receiver, shape.arguments, index, parameters)
        end
        union(inputs)
      end

      private def block_input(
        entry : Index::Def,
        receiver : Resolved,
        arguments : Array(Resolution),
        index : Int32,
        parameters : Int32,
      ) : Resolution
        restriction = block_restriction(entry)
        return yielded(entry, index) unless restriction

        scope = return_scope(entry, receiver, arguments, Site::NONE)
        return scope if scope.is_a?(Unknown)

        if restriction.inputs.size == 1 && parameters > 1
          yielded = @types.resolve(restriction.inputs[0], scope)
          if yielded.is_a?(TypeRef) && yielded.name == "Tuple"
            element = yielded.arguments[index]?
            return element if element
          end
        end
        input = restriction.inputs[index]?
        return Unknown.new(:no_annotation, "#{entry.qualified} yields fewer values") unless input

        @types.resolve(input, scope)
      end

      private def yielded(entry : Index::Def, index : Int32) : Resolution
        definition = entry.node
        unless definition
          return Unknown.new(:no_annotation, "#{entry.qualified} does not state what it yields")
        end

        owner = entry.owner
        enclosing = owner.is_a?(String) ? [owner] : Array(String).new
        sites = Syntax::YieldSites.in(definition, enclosing, entry.free_vars)
        if sites.empty?
          return Unknown.new(:no_annotation, "#{entry.qualified} never yields")
        end

        values = Array(Resolution).new(sites.size)
        sites.each do |site|
          expression = site.node.exps[index]?
          unless expression
            return Unknown.new(:no_annotation, "#{entry.qualified} yields fewer values")
          end
          values << type_of(expression, site.context, [entry.qualified], Array(Binding).new)
        end
        union(values)
      end

      private def block_restriction(entry : Index::Def) : Syntax::Proc?
        restriction = entry.parameters.find(&.kind.block?).try(&.restriction)
        return restriction if restriction.is_a?(Syntax::Proc)

        shim = @shims.find(entry)
        return unless shim

        shimmed = shim.entry.parameters.find(&.kind.block?).try(&.restriction)
        shimmed.is_a?(Syntax::Proc) ? shimmed : nil
      end

      private def bind_block(
        entry : Index::Def,
        site : Site,
        free_vars : Array(String),
        bindings : Array(Binding),
        scope : Scope,
      ) : Nil
        restriction = block_restriction(entry)
        return unless restriction
        output = restriction.output
        return unless output

        block = site.block
        unless block
          passed = site.block_arg
          return unless passed

          result = passed_block_result(passed, site, scope, restriction)
          Unify.bind(output, result, free_vars, bindings, @types, scope)
          return
        end

        inputs = restriction.inputs.map { |input| @types.resolve(input, scope) }
        locals = site.locals.dup
        block.args.each_with_index do |argument, index|
          input = inputs[index]?
          locals << Binding.new(argument.name, input) if input
        end
        body = block.body
        result = type_of(body, site.context.inside(block, body), site.visiting, locals)
        Unify.bind(output, result, free_vars, bindings, @types, scope)
      end

      private def passed_block_result(
        passed : Crystal::ASTNode,
        site : Site,
        scope : Scope,
        restriction : Syntax::Proc,
      ) : Resolution
        if passed.is_a?(Crystal::ProcPointer)
          return proc_pointer_result(passed, site, scope, restriction)
        end

        proc = type_of(passed, site.context, site.visiting, site.locals)
        return proc if proc.is_a?(Unknown)
        if proc.is_a?(TypeRef) && proc.name == "Proc" && (output = proc.arguments.last?)
          return output
        end

        Unknown.new(:no_annotation, "the passed block is a #{proc}, not a Proc with a signature")
      end

      private def proc_pointer_result(
        pointer : Crystal::ProcPointer,
        site : Site,
        scope : Scope,
        restriction : Syntax::Proc,
      ) : Resolution
        inputs = restriction.inputs.map { |input| @types.resolve(input, scope) }
        arguments = Array(Resolution).new(pointer.args.size)
        pointer.args.each_with_index do |argument, index|
          typed = Syntax::TypeReader.read(argument)
          arguments << if typed.is_a?(Syntax::Type)
            @types.resolve(typed, scope(site.context))
          else
            inputs[index]? || Unknown.new(:unsupported, "proc pointer argument #{argument}")
          end
        end
        obj = pointer.obj
        receiver = if obj
                     type_of(obj, site.context, site.visiting, site.locals)
                   else
                     implicit_self(site.context)
                   end
        return receiver if receiver.is_a?(Unknown)

        shape = Methods::Call.new(pointer.name, arguments.size, false, arguments)
        result_of(receiver, shape, Site::NONE)
      end

      private def bind_arguments(
        entry : Index::Def,
        arguments : Array(Resolution),
        free_vars : Array(String),
        bindings : Array(Binding),
        scope : Scope,
      ) : Nil
        positional = entry.parameters.select(&.kind.positional?)
        positional.each_with_index do |parameter, index|
          restriction = parameter.restriction
          next unless restriction.is_a?(Syntax::Type)

          argument = arguments[index]? || defaulted(parameter, scope)
          next unless argument

          Unify.bind(restriction, argument, free_vars, bindings, @types, scope)
        end
      end

      private def defaulted(parameter : Index::Parameter, scope : Scope) : Resolution?
        default_type = parameter.default_type
        default_type ? @types.resolve(default_type, scope) : nil
      end

      private def bind_named(
        entry : Index::Def,
        named : Array(Binding),
        free_vars : Array(String),
        bindings : Array(Binding),
        scope : Scope,
      ) : Nil
        named.each do |argument|
          parameter = entry.parameters.find(&.external_name.==(argument.name))
          restriction = parameter.try(&.restriction)
          next unless restriction.is_a?(Syntax::Type)

          Unify.bind(restriction, argument.value, free_vars, bindings, @types, scope)
        end
      end

      private def scope(context : Syntax::Context) : Scope
        Scope.new(context.owner, context.type_vars)
      end

      private def declared(type : Syntax::TypeReader::Outcome, scope : Scope) : Resolution
        return Unknown.new(:unsupported, type.source) if type.is_a?(Syntax::TypeReader::Unsupported)

        @types.resolve(type, scope)
      end
    end
  end
end
