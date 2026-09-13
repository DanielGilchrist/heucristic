require "compiler/crystal/syntax"
require "../index/workspace"
require "../index/accessor"
require "../index/synthesized"

module Heucristic
  module Check
    module MacroArguments
      extend self

      def within?(ancestors : Array(Crystal::ASTNode), workspace : Index::Workspace) : Bool
        ancestors.each_with_index.any? do |node, index|
          next false unless node.is_a?(Crystal::Call) && node.obj.nil?
          next false unless macro_like?(node.name, workspace)

          block = node.block
          next true if block.nil? || !ancestors[index + 1]?.try(&.same?(block))

          !Index::Synthesized.from_name(node.name).try(&.record?)
        end
      end

      def macro_like?(name : String, workspace : Index::Workspace) : Bool
        !Index::Accessor.from_name(name).nil? || !Index::Synthesized.from_name(name).nil? ||
          !workspace.macros(name).empty?
      end
    end
  end
end
