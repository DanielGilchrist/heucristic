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
          return if !free_vars.includes?(name) || bindings.any?(&.name.==(name))
          return if argument.is_a?(Unknown)

          bindings << Binding.new(name, argument)
        in Syntax::Generic
          return unless argument.is_a?(TypeRef)
          base = types.resolve_lexically(restriction.base, scope)
          return unless base.is_a?(TypeRef) && base.name == argument.name

          restriction.arguments.zip?(argument.arguments) do |inner, value|
            bind(inner, value, free_vars, bindings, types, scope) if value
          end
        in Syntax::Nilable
          inner = argument.is_a?(UnionRef) ? argument.members.reject(&.==(NIL)) : [argument]
          value = inner.size == 1 ? inner[0] : argument
          bind(restriction.inner, value, free_vars, bindings, types, scope)
        in Syntax::Union
          bind_union(restriction, argument, free_vars, bindings, types, scope)
        in Syntax::Proc, Syntax::Metaclass, Syntax::Splat, Syntax::Literal,
           Syntax::TypeOf, Syntax::SelfType, Syntax::Underscore
          nil
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
        return unless argument.is_a?(TypeRef)

        shaped = restriction.members.select(Syntax::Generic).find do |member|
          base = types.resolve_lexically(member.base, scope)
          base.is_a?(TypeRef) && base.name == argument.name
        end
        return bind(shaped, argument, free_vars, bindings, types, scope) if shaped

        bare = restriction.members.select(Syntax::Named).find do |member|
          member.names.size == 1 && free_vars.includes?(member.names[0])
        end
        bind(bare, argument, free_vars, bindings, types, scope) if bare
      end

      private NIL = TypeRef.new("Nil", Array(Resolution).new)
    end
  end
end
