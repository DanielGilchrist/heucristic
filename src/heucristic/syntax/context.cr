require "compiler/crystal/syntax"
require "../index/owner"
require "../index/accessor"

module Heucristic
  module Syntax
    record Context,
      enclosing : Array(String),
      type_vars : Array(String),
      def_node : Crystal::Def?,
      blocks : Array(Crystal::Call),
      ancestors : Array(Crystal::ASTNode),
      path : String? = nil,
      instance : Bool = false do
      def self.new(
        enclosing : Array(String),
        type_vars : Array(String),
        def_node : Crystal::Def?,
        path : String? = nil,
        instance : Bool = false,
      ) : Context
        new(
          enclosing,
          type_vars,
          def_node,
          Array(Crystal::Call).new,
          Array(Crystal::ASTNode).new,
          path,
          instance,
        )
      end

      def instance_code? : Bool
        instance || inside_accessor_block?
      end

      def owner : Index::Owner
        enclosing.last? || Index::TopLevel.new
      end

      def at(path : Array(Crystal::ASTNode)) : Context
        Context.new(enclosing, type_vars, def_node, blocks, path, self.path)
      end

      def at(ancestors : Array(Crystal::ASTNode)) : Context
        entered = ancestors.select(Crystal::Call).select { |call| !call.block.nil? }
        Context.new(enclosing, type_vars, def_node, entered, ancestors, path, instance)
      end

      def inside(node : Crystal::ASTNode) : Context
        return self if ancestors.last?.try(&.same?(node))

        Context.new(enclosing, type_vars, def_node, blocks, ancestors + [node], path, instance)
      end

      def inside(parent : Crystal::ASTNode, child : Crystal::ASTNode) : Context
        inside(parent).inside(child)
      end

      private def inside_accessor_block? : Bool
        ancestors.each_with_index do |node, index|
          next unless node.is_a?(Crystal::Call) && node.obj.nil?

          block = node.block
          next unless block && ancestors[index + 1]?.try(&.same?(block))

          accessor = Index::Accessor.from_name(node.name)
          return true if accessor && accessor.receiver.instance?
        end
        false
      end
    end
  end
end
