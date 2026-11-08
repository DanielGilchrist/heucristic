require "../syntax/type"
require "./resolution"
require "./binding"
require "./scope"

module Heucristic
  module Resolve
    module Unify
      extend self

      def bind(
        restriction : Syntax::Type,
        argument : Resolution,
        free_vars : Array(String),
        bindings : Array(Binding),
        types : Types,
        scope : Scope,
      ) : Nil
        case restriction
        in Syntax::Named
          return if restriction.names.size != 1 || restriction.global?
          name = restriction.names[0]
          return unless free_vars.includes?(name)

          existing = bindings.index(&.name.==(name))
          value = argument
          if argument.is_a?(Unknown)
            value = Unknown.new(argument.reason, "#{name} = #{argument.detail}")
          end
          if existing.nil?
            bindings << Binding.new(name, value)
          elsif bindings[existing].value.is_a?(Unknown) && value.is_a?(Resolved)
            bindings[existing] = Binding.new(name, value)
          end
        in Syntax::Generic
          return unless argument.is_a?(TypeRef)
          base = types.resolve_lexically(restriction.base, scope)
          return unless base.is_a?(TypeRef) && base.identity == argument.identity

          restriction.arguments.zip?(argument.arguments) do |inner, value|
            bind(inner, value, free_vars, bindings, types, scope) if value
          end
        in Syntax::Nilable
          value = argument.is_a?(UnionRef) ? without_nil(argument) : argument
          bind(restriction.inner, value, free_vars, bindings, types, scope)
        in Syntax::Union
          bind_union(restriction, argument, free_vars, bindings, types, scope)
        in Syntax::Proc
          return unless argument.is_a?(TypeRef) && argument.is?(:proc)
          return unless (result = argument.arguments.last?)

          restriction.inputs.zip?(argument.arguments[0...-1]) do |inner, value|
            bind(inner, value, free_vars, bindings, types, scope) if value
          end
          output = restriction.output
          bind(output, result, free_vars, bindings, types, scope) if output
        in Syntax::Metaclass
          instance = instance_of(argument)
          bind(restriction.of, instance, free_vars, bindings, types, scope) if instance
        in Syntax::Splat, Syntax::Literal, Syntax::TypeOf, Syntax::SelfType, Syntax::Underscore
          nil
        end
      end

      private def without_nil(argument : UnionRef) : Resolution
        remaining = argument.members.reject(&.==(NIL))
        remaining.empty? ? argument : UnionRef.join(remaining)
      end

      private def instance_of(argument : Resolution) : Resolution?
        case argument
        in MetaRef then argument.of
        in UnionRef
          members = Array(Resolution).new(argument.members.size)
          argument.members.each do |member|
            instance = instance_of(member)
            return unless instance

            members << instance
          end
          UnionRef.new(members)
        in TypeRef, TypeVar, Unknown, ProgramRef then nil
        end
      end

      private def bind_union(
        restriction : Syntax::Union,
        argument : Resolution,
        free_vars : Array(String),
        bindings : Array(Binding),
        types : Types,
        scope : Scope,
      ) : Nil
        bare = restriction.members.select(Syntax::Named).find do |member|
          member.names.size == 1 && free_vars.includes?(member.names[0])
        end
        if argument.is_a?(Unknown)
          bind(bare, argument, free_vars, bindings, types, scope) if bare
          return
        end
        if argument.is_a?(UnionRef)
          return bind_remaining(restriction, bare, argument, free_vars, bindings, types, scope)
        end
        return unless argument.is_a?(TypeRef) || argument.is_a?(ProgramRef)

        shaped = restriction.members.select(Syntax::Generic).find do |member|
          base = types.resolve_lexically(member.base, scope)
          base.is_a?(TypeRef) && base.identity == argument.identity
        end
        return bind(shaped, argument, free_vars, bindings, types, scope) if shaped

        bind(bare, argument, free_vars, bindings, types, scope) if bare
      end

      private def bind_remaining(
        restriction : Syntax::Union,
        bare : Syntax::Named?,
        argument : UnionRef,
        free_vars : Array(String),
        bindings : Array(Binding),
        types : Types,
        scope : Scope,
      ) : Nil
        return unless bare

        others = restriction.members.reject(&.==(bare))
        concrete = others.map { |member| types.resolve(member, scope) }
        remaining = argument.members.reject do |member|
          concrete.any? { |covering| covers?(covering, member, types) }
        end
        return if remaining.empty?

        value = UnionRef.join(remaining)
        bind(bare, value, free_vars, bindings, types, scope)
      end

      private def covers?(covering : Resolution, member : Resolution, types : Types) : Bool
        return false unless covering.is_a?(TypeRef) && member.is_a?(TypeRef)
        return true if covering == member

        chain = types.ancestors(member.identity)
        !chain.is_a?(Unknown) && chain.includes?(covering.identity)
      end

      private NIL = TypeRef.of(:nil)
    end
  end
end
