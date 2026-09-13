require "compiler/crystal/syntax"
require "../index/workspace"
require "../index/synthesized"
require "../index/macro_call"

module Heucristic
  module Check
    module MacroArguments
      extend self

      def within?(ancestors : Array(Crystal::ASTNode), workspace : Index::Workspace) : Bool
        ancestors.each_with_index.any? do |node, index|
          next false unless node.is_a?(Crystal::Call)
          next false unless Index::MacroCall.like?(node, workspace)

          block = node.block
          next true if block.nil? || !ancestors[index + 1]?.try(&.same?(block))

          !Index::Synthesized.from_name(node.name).try(&.record?)
        end
      end
    end
  end
end
