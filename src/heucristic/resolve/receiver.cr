require "compiler/crystal/syntax"
require "../index/workspace"
require "../index/shims"
require "../index/evident"
require "../syntax/target"
require "../syntax/type_reader"
require "./types"
require "./methods"
require "./unify"
require "./local_declarations"
require "./local_assignments"

module Heucristic
  module Resolve
    class Receiver
      def initialize(
        @workspace : Index::Workspace,
        @shims : Index::Shims,
        @types : Types,
        @methods : Methods,
      ) : Nil
      end

      def result_of(
        call : Crystal::Call,
        context : Syntax::Context,
        locals : Array(Binding) = Array(Binding).new,
      ) : Resolution
        receiver = of_call(call, context, locals)
        return receiver if receiver.is_a?(Unknown)

        result_of(receiver, shape_of(call, context, locals), Site.new(call.block, context, locals))
      end

      def shape_of(
        call : Crystal::Call,
        context : Syntax::Context,
        locals : Array(Binding) = Array(Binding).new,
      ) : Methods::Call
        arguments = call.args.map do |argument|
          type_of(argument, context, Array(String).new, locals)
        end
        named = call.named_args.try(&.map(&.name)) || Array(String).new
        Methods::Call.new(call.name, call.args.size, !call.block.nil?, arguments, named)
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

        results = defs.map { |entry| return_type(entry, receiver, call.arguments, site) }
        distinct = results.uniq
        return distinct[0] if distinct.size == 1

        Unknown.new(:ambiguous, "#{defs.size} overloads of `#{call.name}` do not agree on a type")
      end

      record Site, block : Crystal::Block?, context : Syntax::Context, locals : Array(Binding) do
        NONE = new(
          nil, Syntax::Context.new(Array(String).new, Array(String).new, nil), Array(Binding).new
        )
      end

      def of_call(
        call : Crystal::Call,
        context : Syntax::Context,
        locals : Array(Binding) = Array(Binding).new,
      ) : Resolution
        receiver = call.obj
        return implicit_self(context) unless receiver

        type_of(receiver, context, Array(String).new, locals)
      end

      def variable(name : String, context : Syntax::Context) : Resolution
        variable(name, context, Array(String).new, Array(Binding).new)
      end

      def instance_var(name : String, context : Syntax::Context) : Resolution
        owner = context.owner
        if owner.is_a?(Index::TopLevel)
          return Unknown.new(:no_annotation, "#{name} outside any type")
        end

        entries = @workspace.instance_vars_of(owner).select(&.name.==(name))
        declared = entries.select(&.origin.declared?)
        sources = declared.empty? ? entries : declared
        if sources.empty?
          return Unknown.new(
            :no_annotation, "#{name} is never declared or assigned an evident type in #{owner}"
          )
        end

        scope = Scope.of(owner)
        union(sources.map { |entry| declared(entry.type, scope) })
      end

      private def type_of(
        node : Crystal::ASTNode,
        context : Syntax::Context,
        visiting : Array(String),
        locals : Array(Binding),
      ) : Resolution
        evident = Index::Evident.type(node)
        return declared(evident, scope(context)) if evident.is_a?(Syntax::Type)

        case node
        when Crystal::Var         then variable(node.name, context, visiting, locals)
        when Crystal::InstanceVar then instance_var(node.name, context)
        when Crystal::Call        then result_of(node, context, locals)
        when Crystal::Expressions
          if node.expressions.size == 1
            type_of(node.expressions[0], context, visiting, locals)
          else
            Unknown.new(:inference_needed, "the type of `#{node}` is not written in the source")
          end
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
          return local.value
        end

        definition = context.def_node
        return Unknown.new(:no_annotation, "#{name} is outside any method") unless definition

        if (parameter = definition.args.find(&.name.==(name)))
          restriction = parameter.restriction
          unless restriction
            return Unknown.new(:no_annotation, "parameter #{name} has no type restriction")
          end
          return declared(Syntax::TypeReader.read(restriction), scope(context))
        end

        if (declaration = LocalDeclarations.find(definition.body, name))
          return declared(Syntax::TypeReader.read(declaration.declared_type), scope(context))
        end

        return Unknown.new(:cycle, name) if visiting.includes?(name)

        if (from_block = block_parameter(name, context, locals))
          return from_block
        end

        assignments = LocalAssignments.find(definition.body, name)
        if assignments.empty?
          return Unknown.new(
            :no_annotation, "#{name} is not a parameter and is never assigned here"
          )
        end

        union(assignments.map { |value| type_of(value, context, visiting + [name], locals) })
      end

      private def union(resolutions : Array(Resolution)) : Resolution
        members = Array(Resolution).new
        resolutions.each do |resolution|
          return resolution if resolution.is_a?(Unknown)
          members << resolution unless members.includes?(resolution)
        end
        members.size == 1 ? members[0] : UnionRef.new(members)
      end

      private def implicit_self(context : Syntax::Context) : Resolution
        owner = context.owner
        return Unknown.new(:top_level, "no enclosing type") if owner.is_a?(Index::TopLevel)

        this = TypeRef.new(owner, Array(Resolution).new)
        definition = context.def_node
        definition && definition.receiver ? MetaRef.new(this) : this
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

        case (restriction = entry.return_type)
        in Index::Unrestricted
          shim = @shims.find(entry)
          return return_type(shim.entry, receiver, arguments, site) if shim

          Unknown.new(:no_annotation, "#{entry.qualified} has no return type restriction")
        in Syntax::TypeReader::Unsupported
          Unknown.new(:unsupported, restriction.source)
        in Syntax::Type
          scope = return_scope(entry, receiver, arguments, site)
          return scope if scope.is_a?(Unknown)

          @types.resolve(restriction, scope)
        end
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
        unless owner.is_a?(Index::TopLevel)
          instance = receiver.is_a?(MetaRef) ? receiver.of : receiver
          inherited = instance.is_a?(TypeRef) ? @types.bindings(instance, owner) : bindings
          return inherited if inherited.is_a?(Unknown)
          bindings = inherited.dup
          type_vars = @types.type_vars_of(owner) + type_vars
        end

        scope = Scope.new(owner, type_vars, bindings)
        bind_arguments(entry, arguments, bindings, scope)
        bind_block(entry, site, bindings, scope)
        scope
      end

      private def block_parameter(
        name : String,
        context : Syntax::Context,
        locals : Array(Binding),
      ) : Resolution?
        context.blocks.reverse_each do |call|
          block = call.block
          next unless block
          index = block.args.index(&.name.==(name))
          next unless index

          enclosing_blocks = context.blocks[0...context.blocks.index!(call)]
          outer = Syntax::Context.new(
            context.enclosing, context.type_vars, context.def_node, enclosing_blocks
          )
          receiver = of_call(call, outer, locals)
          return receiver if receiver.is_a?(Unknown)

          shape = shape_of(call, outer, locals)
          defs = @methods.lookup(receiver, shape)
          return Unknown.new(:unresolved_name, "no `#{call.name}` on #{receiver}") if defs.empty?

          inputs = defs.map { |entry| block_input(entry, receiver, shape.arguments, index) }
          distinct = inputs.uniq
          return distinct[0] if distinct.size == 1

          return Unknown.new(
            :ambiguous, "#{defs.size} overloads of `#{call.name}` yield different types"
          )
        end
        nil
      end

      private def block_input(
        entry : Index::Def,
        receiver : Resolved,
        arguments : Array(Resolution),
        index : Int32,
      ) : Resolution
        restriction = block_restriction(entry)
        unless restriction
          return Unknown.new(:no_annotation, "#{entry.qualified} does not state what it yields")
        end
        input = restriction.inputs[index]?
        return Unknown.new(:no_annotation, "#{entry.qualified} yields fewer values") unless input

        scope = return_scope(entry, receiver, arguments, Site::NONE)
        return scope if scope.is_a?(Unknown)

        @types.resolve(input, scope)
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
        bindings : Array(Binding),
        scope : Scope,
      ) : Nil
        block = site.block
        return unless block
        restriction = block_restriction(entry)
        return unless restriction
        output = restriction.output
        return unless output

        inputs = restriction.inputs.map { |input| @types.resolve(input, scope) }
        locals = site.locals.dup
        block.args.each_with_index do |argument, index|
          input = inputs[index]?
          locals << Binding.new(argument.name, input) if input
        end
        body = last_expression(block.body)
        return unless body

        result = type_of(body, site.context, Array(String).new, locals)
        Unify.bind(output, result, entry.free_vars, bindings, @types, scope)
      end

      private def last_expression(body : Crystal::ASTNode) : Crystal::ASTNode?
        case body
        when Crystal::Expressions then body.expressions.last?
        when Crystal::Nop         then nil
        else                           body
        end
      end

      private def bind_arguments(
        entry : Index::Def,
        arguments : Array(Resolution),
        bindings : Array(Binding),
        scope : Scope,
      ) : Nil
        positional = entry.parameters.select(&.kind.positional?)
        positional.zip?(arguments) do |parameter, argument|
          restriction = parameter.restriction
          next unless argument && restriction.is_a?(Syntax::Type)

          Unify.bind(restriction, argument, entry.free_vars, bindings, @types, scope)
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
