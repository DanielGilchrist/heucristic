require "compiler/crystal/syntax"
require "./workspace"
require "./accessor"
require "./synthesized"

module Heucristic
  module Index
    module MacroCall
      extend self

      def splices_block?(call : Crystal::Call, workspace : Workspace) : Bool
        return false unless call.block

        macros = workspace.macros(call.name)
        !macros.empty? && macros.all?(&.splices_block)
      end

      def like?(call : Crystal::Call, workspace : Workspace) : Bool
        name = call.name
        receiver = call.obj
        if receiver.nil?
          return true if Accessor.from_name(name) || Synthesized.from_name(name)

          return workspace.macros(name).any?(&.arity.accepts?(call.args.size))
        end
        return false unless receiver.is_a?(Crystal::Path)

        target = receiver.names.join("::")
        workspace.macros(name).any? do |entry|
          owner = entry.owner
          entry.arity.accepts?(call.args.size) && owner.is_a?(String) &&
            (owner == target || owner.ends_with?("::#{target}"))
        end
      end

      def enclosing(ancestors : Array(Crystal::ASTNode), workspace : Workspace) : Crystal::Call?
        ancestors.reverse_each do |node|
          next unless node.is_a?(Crystal::Call) && like?(node, workspace)
          next if node.obj.nil? && Synthesized.from_name(node.name).try(&.record?)
          next if splices_block?(node, workspace)

          return node
        end
        nil
      end

      def fitting(call : Crystal::Call, workspace : Workspace) : Array(MacroDef)
        workspace.macros(call.name).select(&.arity.accepts?(call.args.size))
      end
    end
  end
end
