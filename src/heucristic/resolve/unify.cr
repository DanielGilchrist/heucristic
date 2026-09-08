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
        in Syntax::Union, Syntax::Proc, Syntax::Metaclass, Syntax::Splat, Syntax::Literal,
           Syntax::TypeOf, Syntax::SelfType, Syntax::Underscore
          nil
        end
      end

      private NIL = TypeRef.new("Nil", Array(Resolution).new)
    end
  end
end
