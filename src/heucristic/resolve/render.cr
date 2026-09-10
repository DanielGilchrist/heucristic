require "../syntax/type"
require "./types"
require "./scope"

module Heucristic
  module Resolve
    module Render
      extend self

      def type(syntax : Syntax::Type, scope : Scope, types : Types) : String
        case syntax
        in Syntax::Named
          if syntax.names.size == 1 && !syntax.global? && (bound = scope.bound(syntax.names[0]))
            return bound.to_s if bound.is_a?(Resolved)
            return syntax.to_s
          end
          resolved = types.resolve(syntax, scope)
          resolved.is_a?(TypeRef) && resolved.arguments.empty? ? resolved.name : syntax.to_s
        in Syntax::Generic
          arguments = syntax.arguments.map { |argument| nested(argument, scope, types) }
          named = syntax.named_arguments.map do |argument|
            "#{argument.name}: #{nested(argument.type, scope, types)}"
          end
          "#{type(syntax.base, scope, types)}(#{(arguments + named).join(", ")})"
        in Syntax::Union
          syntax.members.map { |member| nested(member, scope, types) }.join(" | ")
        in Syntax::Nilable
          inner = syntax.inner
          wrapped = inner.is_a?(Syntax::Union) || inner.is_a?(Syntax::Proc)
          wrapped ? "(#{type(inner, scope, types)})?" : "#{type(inner, scope, types)}?"
        in Syntax::Proc
          inputs = syntax.inputs.map { |input| nested(input, scope, types) }.join(", ")
          output = syntax.output
          head = inputs.empty? ? "->" : "#{inputs} ->"
          output ? "#{head} #{nested(output, scope, types)}" : head
        in Syntax::Metaclass
          "#{nested(syntax.of, scope, types)}.class"
        in Syntax::Splat
          "*#{nested(syntax.inner, scope, types)}"
        in Syntax::Literal, Syntax::TypeOf, Syntax::SelfType, Syntax::Underscore
          syntax.to_s
        end
      end

      private def nested(syntax : Syntax::Type, scope : Scope, types : Types) : String
        rendered = type(syntax, scope, types)
        syntax.is_a?(Syntax::Proc) ? "(#{rendered})" : rendered
      end
    end
  end
end
