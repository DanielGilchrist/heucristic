require "../index/restriction"
require "../syntax/target"
require "./literal_target"
require "./methods"
require "./receiver"
require "./resolution"
require "./scope"
require "./types"
require "./not_declared"

module Heucristic
  module Resolve
    class Autocasts
      UNDECIDED = Unknown.new(:inference_needed, "a literal takes the parameter's type")

      def initialize(@types : Types, @methods : Methods, @receiver : Receiver) : Nil
        @target = LiteralTarget.new(@methods)
      end

      def of(target : Syntax::OnAutocast) : Resolution
        own = @receiver.typed(target.node, target.context)
        return own unless own.is_a?(TypeRef)

        placement = target.placement
        case placement
        in Syntax::FreePlacement
          own
        in Syntax::DeclaredPlacement
          @target.choose(own, [@receiver.resolved(placement.type, target.context)])
        in Syntax::LocalPlacement
          local(own, placement, target.context)
        in Syntax::InstanceVarPlacement
          instance_var(own, placement, target.context)
        in Syntax::ArgumentPlacement
          argument(own, placement, target.context)
        in Syntax::ConstructedPlacement
          constructed(own, placement, target.context)
        end
      end

      private def instance_var(
        own : TypeRef,
        placement : Syntax::InstanceVarPlacement,
        context : Syntax::Context,
      ) : Resolution
        declared = @receiver.declared_instance_var(placement.name, context)
        case declared
        in NotDeclared then own
        in Resolution  then @target.choose(own, [declared])
        end
      end

      private def local(
        own : TypeRef,
        placement : Syntax::LocalPlacement,
        context : Syntax::Context,
      ) : Resolution
        declared = @receiver.declared_local(placement.name, context)
        case declared
        in NotDeclared then own
        in Resolution  then @target.choose(own, [declared])
        end
      end

      private def constructed(
        own : TypeRef,
        placement : Syntax::ConstructedPlacement,
        context : Syntax::Context,
      ) : Resolution
        instance = @receiver.resolved(placement.type, context)
        case instance
        in TypeRef
          return own if instance.arguments.empty? && !@types.type_vars_of(instance.identity).empty?

          operation = placement.operation
          arity = operation.store? ? 2 : 1
          shape = Methods::CallShape.of_types(
            operation.method_name, Array(Resolution).new(arity) { UNDECIDED }, false
          )
          found = @receiver.implementations(instance, shape)
          if found.empty?
            detail = "no `#{operation.method_name}` is indexed on #{instance}"
            return Unknown.new(:inference_needed, detail)
          end

          expected = found.map { |entry| @methods.expected_at(entry, placement.slot, instance) }
          @target.choose(own, expected)
        in Unknown
          instance
        in UnionRef, MetaRef, TypeVar, ProgramRef
          Unknown.new(:inference_needed, "a collection literal's type must be a single type")
        end
      end

      private def argument(
        own : TypeRef,
        placement : Syntax::ArgumentPlacement,
        context : Syntax::Context,
      ) : Resolution
        call = placement.call
        receiver = @receiver.of_call(call, context)
        if receiver.is_a?(Unknown)
          detail = "a literal argument takes the parameter's type, and the receiver of " \
                   "`#{call.name}` is unknown: #{receiver.detail}"
          return Unknown.new(receiver.reason, detail)
        end

        shape = unconverted(call, @receiver.shape_of(call, context))
        found = @receiver.implementations(receiver, shape)
        if found.empty?
          detail = "a literal argument takes the parameter's type, and `#{call.name}` " \
                   "does not resolve"
          return Unknown.new(:inference_needed, detail)
        end

        instance = @methods.instance_of(receiver)
        accepting = found.select do |entry|
          @methods.compatible?(entry, shape, instance) &&
            literals_fit?(call, entry, receiver, context)
        end
        if accepting.empty?
          detail = "no overload of `#{call.name}` accepts the other arguments of the call"
          return Unknown.new(:inference_needed, detail)
        end

        expected = accepting.map { |entry| @methods.expected_at(entry, placement.slot, receiver) }
        @target.choose(own, expected)
      end

      private def unconverted(call : Crystal::Call, shape : Methods::CallShape) : Methods::CallShape
        types = shape.types.map_with_index do |type, index|
          LiteralTarget.autocastable?(call.args[index]) ? UNDECIDED : type
        end
        shape.with_types(types)
      end

      private def literals_fit?(
        call : Crystal::Call,
        entry : Index::Def,
        receiver : Resolved,
        context : Syntax::Context,
      ) : Bool
        call.args.each_with_index.all? do |argument, index|
          next true unless LiteralTarget.autocastable?(argument)

          own = @receiver.typed(argument, context)
          next true unless own.is_a?(TypeRef)

          expected = @methods.expected_at(entry, Syntax::PositionalSlot.new(index), receiver)
          @target.admits?(expected, own)
        end
      end
    end
  end
end
