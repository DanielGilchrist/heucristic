require "compiler/crystal/syntax"
require "./type"

module Heucristic
  module Syntax
    module TypeReader
      extend self

      record Unsupported, kind : String, source : String

      alias Outcome = Type | Unsupported

      def read(node : Crystal::ASTNode) : Outcome
        case node
        when Crystal::Path          then Named.new(node.names, node.global?)
        when Crystal::Union         then read_union(node)
        when Crystal::Generic       then read_generic(node)
        when Crystal::ProcNotation  then read_proc(node)
        when Crystal::Metaclass     then wrap(node.name) { |inner| Metaclass.new(inner) }
        when Crystal::Splat         then wrap(node.exp) { |inner| Splat.new(inner) }
        when Crystal::NumberLiteral then Literal.new(node.to_s)
        when Crystal::TypeOf        then TypeOf.new(node.expressions.join(", "))
        when Crystal::Self          then SelfType.new
        when Crystal::Underscore    then Underscore.new
        else                             Unsupported.new(node.class.name, node.to_s)
        end
      end

      private def read_union(node : Crystal::Union) : Outcome
        members = read_all(node.types)
        return members if members.is_a?(Unsupported)
        return members[0] if members.size == 1

        if members.size == 2 && nil_marker?(node.types[1])
          Nilable.new(members[0])
        else
          Union.new(members)
        end
      end

      private def read_generic(node : Crystal::Generic) : Outcome
        base = node.name
        return Unsupported.new(base.class.name, node.to_s) unless base.is_a?(Crystal::Path)

        arguments = read_all(node.type_vars)
        return arguments if arguments.is_a?(Unsupported)

        named = Array(Generic::NamedArgument).new
        node.named_args.try &.each do |argument|
          value = read(argument.value)
          return value if value.is_a?(Unsupported)
          named << Generic::NamedArgument.new(argument.name, value)
        end

        Generic.new(Named.new(base.names, base.global?), arguments, named)
      end

      private def read_proc(node : Crystal::ProcNotation) : Outcome
        inputs = read_all(node.inputs || Array(Crystal::ASTNode).new)
        return inputs if inputs.is_a?(Unsupported)

        output = node.output
        return Proc.new(inputs, nil) unless output

        wrap(output) { |result| Proc.new(inputs, result) }
      end

      private def read_all(nodes : Array(Crystal::ASTNode)) : Array(Type) | Unsupported
        types = Array(Type).new(nodes.size)
        nodes.each do |node|
          type = read(node)
          return type if type.is_a?(Unsupported)
          types << type
        end
        types
      end

      private def wrap(node : Crystal::ASTNode, & : Type -> Type) : Outcome
        inner = read(node)
        return inner if inner.is_a?(Unsupported)

        yield inner
      end

      private def nil_marker?(node : Crystal::ASTNode) : Bool
        node.is_a?(Crystal::Path) && node.global? && node.names == ["Nil"]
      end
    end
  end
end
