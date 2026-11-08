require "../core_type"
require "../syntax/type_reader"
require "./flow"
require "./methods"
require "./resolution"
require "./scope"
require "./types"
require "./unions"

module Heucristic
  module Resolve
    class Narrowing
      FALSEY = {CoreType::Nil, CoreType::Bool, CoreType::Pointer}

      def self.assigning?(step : Flow::Step) : Bool
        case step
        in Flow::Assigned, Flow::Reassigned, Flow::OrAssigned, Flow::Declared then true
        in Flow::Branched                                                     then step.assigns
        in Flow::Truthy, Flow::IsA, Flow::RespondsTo                          then false
        end
      end

      def initialize(@types : Types, @methods : Methods, @unions : Unions) : Nil
      end

      def apply(
        current : Resolution,
        step : Flow::Truthy | Flow::IsA | Flow::RespondsTo,
        context : Syntax::Context,
      ) : Resolution
        case step
        in Flow::Truthy     then step.positive ? truthy(current) : falsey(current)
        in Flow::IsA        then typed_as(current, step.types, step.positive, context)
        in Flow::RespondsTo then responding(current, step.method, step.positive, context)
        end
      end

      def truthy(current : Resolution) : Resolution
        return current if current.is_a?(Unknown)

        kept = UnionRef.members_of(current).select do |member|
          member.is_a?(Unknown) || !(member.is_a?(TypeRef) && member.is?(:nil))
        end
        UnionRef.join(kept)
      end

      def falsey(current : Resolution) : Resolution
        return current if current.is_a?(Unknown)

        kept = UnionRef.members_of(current).select do |member|
          member.is_a?(Unknown) || falsey_member?(member)
        end
        UnionRef.join(kept)
      end

      def typed_as(
        current : Resolution,
        types : Array(Crystal::ASTNode),
        positive : Bool,
        context : Syntax::Context,
      ) : Resolution
        targets = Array(TypeRef).new
        types.each do |type|
          resolved = @types.resolve(Syntax::TypeReader.read(type), Scope.of(context))
          case resolved
          in TypeRef then targets << resolved
          in UnionRef
            resolved.members.each do |member|
              return current unless member.is_a?(TypeRef)

              targets << member
            end
          in MetaRef, TypeVar, Unknown then return current
          end
        end

        if current.is_a?(Unknown) || current.is_a?(TypeVar)
          return current unless positive
          return targets[0] if targets.size == 1

          widened = Array(Resolution).new(targets.size)
          targets.each { |target| widened << target }
          return UnionRef.new(widened)
        end

        members = UnionRef.members_of(current)
        kept = Array(Resolution).new
        members.each do |member|
          unless member.is_a?(TypeRef)
            kept << member
            next
          end
          matched = targets.any? { |target| @unions.covers?(target, member) }
          if positive
            kept << member if matched
            targets.each { |target| kept << target if !matched && @unions.covers?(member, target) }
          else
            kept << member unless matched
          end
        end
        UnionRef.join(kept)
      end

      def responding(
        current : Resolution,
        method : String,
        positive : Bool,
        context : Syntax::Context,
      ) : Resolution
        return current if current.is_a?(Unknown)

        members = UnionRef.members_of(current)
        kept = Array(Resolution).new(members.size)
        members.each do |member|
          next kept << member unless member.is_a?(TypeRef) || member.is_a?(MetaRef)

          responds = !@methods.named_on(member, method, context.path).empty?
          if positive && !responds
            @methods.virtual_receivers(member, context.path).each do |below|
              kept << below unless @methods.named_on(below, method, context.path).empty?
            end
          elsif positive == responds
            kept << member
          end
        end
        UnionRef.join(kept)
      end

      private def falsey_member?(member : Resolution) : Bool
        member.is_a?(TypeRef) && FALSEY.any? { |core| member.is?(core) }
      end
    end
  end
end
