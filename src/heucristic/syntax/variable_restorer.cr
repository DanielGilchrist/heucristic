require "compiler/crystal/syntax"

module Heucristic
  module Syntax
    class VariableRestorer < Crystal::Transformer
      def initialize(@variables : Set(String)) : Nil
      end

      def transform(node : Crystal::Call) : Crystal::ASTNode
        return super unless bare_variable?(node)

        Crystal::Var.new(node.name).at(node)
      end

      private def bare_variable?(node : Crystal::Call) : Bool
        node.obj.nil? && node.args.empty? && node.block.nil? && node.block_arg.nil? &&
          node.named_args.nil? && @variables.includes?(node.name)
      end
    end
  end
end
