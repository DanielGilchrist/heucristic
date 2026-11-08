require "compiler/crystal/syntax"
require "../index/workspace"
require "../index/macro_def"
require "./methods"
require "./resolution"

module Heucristic
  module Resolve
    class MacroPrecedence
      enum Verdict
        Macro
        Def
        Undecided
      end

      def initialize(@workspace : Index::Workspace, @methods : Methods) : Nil
      end

      def verdict(call : Crystal::Call, scope : Resolution, path : String?) : Verdict
        macros = @workspace.macros(call.name)
        return Verdict::Def if macros.empty? || !call.obj.nil?

        undecidable = call.args.any? { |arg| splat?(arg) } || !call.block_arg.nil?
        case scope
        in TypeRef
          return top_level(macros, call, undecidable) if scope.program?

          walk(scope.name, Index::Receiver::Instance, macros, call, undecidable, path)
        in MetaRef
          of = scope.of
          return Verdict::Def if of.is_a?(TypeVar)

          walk(of.name, Index::Receiver::Metaclass, macros, call, undecidable, path)
        in UnionRef, TypeVar, Unknown then Verdict::Def
        end
      end

      private def walk(
        type : String,
        kind : Index::Receiver,
        macros : Array(Index::MacroDef),
        call : Crystal::Call,
        undecidable : Bool,
        path : String?,
      ) : Verdict
        @methods.levels(type).each do |level|
          here = macros.select(&.owner.==(level))
          unless here.empty?
            return Verdict::Undecided if undecidable
            return Verdict::Macro if here.any?(&.accepts?(call))
          end
          return Verdict::Def if defined_at?(level, kind, call.name, path)
        end
        top_level(macros, call, undecidable)
      end

      private def top_level(
        macros : Array(Index::MacroDef),
        call : Crystal::Call,
        undecidable : Bool,
      ) : Verdict
        here = macros.select(&.owner.is_a?(Index::TopLevel))
        return Verdict::Def if here.empty?
        return Verdict::Undecided if undecidable

        here.any?(&.accepts?(call)) ? Verdict::Macro : Verdict::Def
      end

      private def defined_at?(
        level : String,
        kind : Index::Receiver,
        name : String,
        path : String?,
      ) : Bool
        @workspace.named(name).any? do |entry|
          entry.owner == level && entry.receiver == kind && @methods.own?(entry, path)
        end
      end

      private def splat?(node : Crystal::ASTNode) : Bool
        node.is_a?(Crystal::Splat) || node.is_a?(Crystal::DoubleSplat)
      end
    end
  end
end
