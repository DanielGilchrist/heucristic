require "compiler/crystal/syntax"
require "../index/restriction"
require "./literal_fit"
require "./methods"
require "./resolution"

module Heucristic
  module Resolve
    class LiteralTarget
      alias Expected = Resolution | Index::Unrestricted | Methods::NoParameter
      alias Member = TypeRef | MetaRef | ProgramRef | TypeVar | Unknown | Index::Unrestricted |
                     Methods::NoParameter

      def self.autocastable?(node : Crystal::ASTNode) : Bool
        node.is_a?(Crystal::NumberLiteral | Crystal::SymbolLiteral)
      end

      def initialize(@methods : Methods) : Nil
      end

      def choose(own : TypeRef, expected : Array(Expected)) : Resolution
        casts = Array(TypeRef).new
        unknown = nil
        expected.flat_map { |entry| flatten(entry) }.each do |member|
          case member
          in Index::Unrestricted then return own
          in TypeVar
            unknown ||= Unknown.new(
              :free_variable, "the parameter's type #{member} is not bound by the receiver"
            )
          in Unknown then unknown ||= member
          in TypeRef
            case @methods.literal_fit(member, own)
            in .own?     then return own
            in .cast?    then casts << member
            in .neither? then nil
            end
          in Methods::NoParameter, MetaRef, ProgramRef then nil
          end
        end

        casts.uniq!
        return casts.first if casts.size == 1
        return unknown if unknown && casts.empty?

        if casts.empty?
          return Unknown.new(:inference_needed, "no accepted type admits the #{own} literal")
        end

        Unknown.new(
          :ambiguous, "the #{own} literal converts to several accepted types: #{casts.join(", ")}"
        )
      end

      def admits?(expected : Expected, own : TypeRef) : Bool
        flatten(expected).any? { |member| admits_member?(member, own) }
      end

      private def flatten(entry : Expected) : Array(Member)
        case entry
        in UnionRef
          entry.members.flat_map { |member| flatten(member) }
        in Index::Unrestricted, TypeVar, Unknown, TypeRef, Methods::NoParameter, MetaRef, ProgramRef
          [entry] of Member
        end
      end

      private def admits_member?(member : Member, own : TypeRef) : Bool
        case member
        in TypeRef
          !@methods.literal_fit(member, own).neither?
        in Index::Unrestricted, TypeVar, Unknown, Methods::NoParameter
          true
        in MetaRef, ProgramRef
          false
        end
      end
    end
  end
end
