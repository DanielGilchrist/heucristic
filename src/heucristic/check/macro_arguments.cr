require "compiler/crystal/syntax"
require "../index/workspace"
require "../index/synthesized"
require "../index/macro_call"

module Heucristic
  module Check
    module MacroArguments
      extend self

      def within?(ancestors : Array(Crystal::ASTNode), workspace : Index::Workspace) : Bool
        ancestors.each_with_index do |node, index|
          return true if node.is_a?(Crystal::Annotation)
          next unless node.is_a?(Crystal::Call)
          next unless Index::MacroCall.like?(node, workspace)

          block = node.block
          return true if block.nil? || !ancestors[index + 1]?.try(&.same?(block))
          next if Index::MacroCall.splices_block?(node, workspace)

          return true unless Index::Synthesized.from_name(node.name).try(&.record?)
        end
        false
      end
    end
  end
end
