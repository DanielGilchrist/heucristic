require "../resolve/methods"
require "../resolve/resolution"
require "../core_type"

module Heucristic
  module Check
    struct Fit
      def initialize(@methods : Resolve::Methods) : Nil
      end

      def checkable?(expected : Resolve::Resolution) : Bool
        case expected
        in Resolve::TypeRef
          !expected.is?(:nil) && !expected.is?(:no_return) && expected.name != "Void"
        in Resolve::UnionRef
          expected.members.all?(Resolve::TypeRef)
        in Resolve::MetaRef, Resolve::TypeVar, Resolve::Unknown
          false
        end
      end

      def fits?(expected : Resolve::Resolution, actual : Resolve::Resolved) : Bool
        return true if actual.is_a?(Resolve::TypeRef) && actual.is?(:no_return)
        return true if actual.is_a?(Resolve::TypeVar) || actual.is_a?(Resolve::MetaRef)
        if actual.is_a?(Resolve::UnionRef)
          return actual.members.any? do |member|
            member.is_a?(Resolve::Unknown) || fits?(expected, member)
          end
        end

        @methods.admits?(expected, actual)
      end

      def numeric?(expected : Resolve::Resolution) : Bool
        case expected
        in Resolve::TypeRef
          CoreType.from_name(expected.name).try(&.numeric?) || false
        in Resolve::UnionRef
          expected.members.any? { |member| numeric?(member) }
        in Resolve::MetaRef, Resolve::TypeVar, Resolve::Unknown then true
        end
      end

      def nilable?(expected : Resolve::Resolution) : Bool
        case expected
        in Resolve::TypeRef then expected.is?(:nil)
        in Resolve::UnionRef
          expected.members.any? do |member|
            member.is_a?(Resolve::Unknown) || (member.is_a?(Resolve::TypeRef) && member.is?(:nil))
          end
        in Resolve::MetaRef, Resolve::TypeVar, Resolve::Unknown then true
        end
      end
    end
  end
end
