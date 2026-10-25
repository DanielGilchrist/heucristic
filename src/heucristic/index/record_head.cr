require "compiler/crystal/syntax"
require "./synthesized"

module Heucristic
  module Index
    record RecordHead, name : Crystal::Path, type_vars : Array(String) do
      def self.of(call : Crystal::Call) : RecordHead?
        return unless call.obj.nil? && Synthesized.from_name(call.name).try(&.record?)

        case (head = call.args[0]?)
        in Crystal::Path then new(head, Array(String).new)
        in Crystal::Generic
          name = head.name
          return unless name.is_a?(Crystal::Path)

          new(name, head.type_vars.compact_map { |var| variable_name(var) })
        in Crystal::ASTNode, Nil then nil
        end
      end

      private def self.variable_name(node : Crystal::ASTNode) : String?
        node.names.first? if node.is_a?(Crystal::Path)
      end
    end
  end
end
