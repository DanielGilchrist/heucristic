require "./resolution"
require "./scope"
require "./types"

module Heucristic
  module Resolve
    class Unions
      def initialize(@types : Types) : Nil
      end

      def union(resolutions : Array(Resolution)) : Resolution
        members = Array(Resolution).new
        resolutions.each do |resolution|
          return resolution if resolution.is_a?(Unknown)
          next if resolution.is_a?(TypeRef) && resolution.is?(:no_return)
          UnionRef.members_of(resolution).each do |inner|
            members << inner unless members.includes?(inner)
          end
        end
        return TypeRef.of(:no_return) if members.empty?

        UnionRef.join(absorb(members))
      end

      def covers?(ancestor : TypeRef, descendant : TypeRef) : Bool
        return true if ancestor.identity == descendant.identity

        chain = @types.ancestors(descendant.identity)
        !chain.is_a?(Unknown) && chain.includes?(ancestor.identity)
      end

      def metaclass_of(resolved : Resolution) : Resolution
        case resolved
        in TypeRef, TypeVar then MetaRef.new(resolved)
        in UnionRef
          members = Array(Resolution).new(resolved.members.size)
          resolved.members.each { |member| members << metaclass_of(member) }
          UnionRef.new(members)
        in MetaRef, Unknown then resolved
        in ProgramRef
          Unknown.new(:unsupported, "the metaclass of the top-level program")
        end
      end

      def rebind(resolution : Resolution, scope : Scope) : Resolution
        case resolution
        in TypeVar then scope.bound(resolution.name) || resolution
        in TypeRef
          TypeRef.new(
            resolution.identity,
            resolution.arguments.map { |arg| rebind(arg, scope) },
            bare: resolution.bare,
          )
        in UnionRef then union(resolution.members.map { |member| rebind(member, scope) })
        in MetaRef
          inner = rebind(resolution.of, scope)
          inner.is_a?(TypeRef) || inner.is_a?(TypeVar) ? MetaRef.new(inner) : resolution
        in Unknown, ProgramRef then resolution
        end
      end

      private def absorb(members : Array(Resolution)) : Array(Resolution)
        return members if members.size < 2

        members.reject do |member|
          next false unless member.is_a?(TypeRef)

          members.any? do |other|
            other.is_a?(TypeRef) && other.identity != member.identity &&
              other.arguments.empty? && covers?(other, member)
          end
        end
      end
    end
  end
end
