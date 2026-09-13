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

          return !workspace.macros(name).empty?
        end
        return false unless receiver.is_a?(Crystal::Path)

        target = receiver.names.join("::")
        workspace.macros(name).any? do |entry|
          owner = entry.owner
          owner.is_a?(String) && (owner == target || owner.ends_with?("::#{target}"))
        end
      end
    end
  end
end
