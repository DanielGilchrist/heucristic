require "compiler/crystal/syntax"
require "../index/owner"

module Heucristic
  module Syntax
    record Context,
      enclosing : Array(String),
      type_vars : Array(String),
      def_node : Crystal::Def?,
      blocks : Array(Crystal::Call),
      ancestors : Array(Crystal::ASTNode),
      path : String? = nil do
      def self.new(
        enclosing : Array(String),
        type_vars : Array(String),
        def_node : Crystal::Def?,
        path : String? = nil,
      ) : Context
        new(
          enclosing,
          type_vars,
          def_node,
          Array(Crystal::Call).new,
          Array(Crystal::ASTNode).new,
          path,
        )
      end

      def owner : Index::Owner
        enclosing.last? || Index::TopLevel.new
      end

      def at(path : Array(Crystal::ASTNode)) : Context
        Context.new(enclosing, type_vars, def_node, blocks, path, self.path)
      end

      def at(ancestors : Array(Crystal::ASTNode)) : Context
        entered = ancestors.select(Crystal::Call).select { |call| !call.block.nil? }
        Context.new(enclosing, type_vars, def_node, entered, ancestors, path)
      end

      def inside(node : Crystal::ASTNode) : Context
        return self if ancestors.last?.try(&.same?(node))

        Context.new(enclosing, type_vars, def_node, blocks, ancestors + [node], path)
      end

      def inside(parent : Crystal::ASTNode, child : Crystal::ASTNode) : Context
        inside(parent).inside(child)
      end
    end
  end
end
