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
        instance || accessor_block.try(&.receiver.instance?) || false
      end

      def method_body? : Bool
        !def_node.nil? || !accessor_block.nil?
      end

      def proc_index : Int32?
        definition = def_node
        return unless definition

        ancestors.rindex do |node|
          node.is_a?(Crystal::ProcLiteral) && node.def.same?(definition)
        end
      end

      def outside_proc(index : Int32) : Context
        outer = ancestors[0, index + 1]
        entered = outer.select(Crystal::Call).select { |call| !call.block.nil? }
        Context.new(enclosing, type_vars, enclosing_def(outer), entered, outer, path, instance)
      end

      def select_condition?(call : Crystal::Call) : Bool
        ancestors.each_with_index.any? do |node, index|
          next false unless node.is_a?(Crystal::Select)
          branch = ancestors[index + 1]?
          next false unless branch.is_a?(Crystal::When)

          inner = ancestors[index + 2]? || call
          branch.conds.any?(&.same?(inner))
        end
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

      private def enclosing_def(nodes : Array(Crystal::ASTNode)) : Crystal::Def?
        nodes.reverse_each do |node|
          return node if node.is_a?(Crystal::Def)
        end
      end

      private def accessor_block : Index::Accessor?
        ancestors.each_with_index do |node, index|
          next unless node.is_a?(Crystal::Call) && node.obj.nil?

          block = node.block
          next unless block && ancestors[index + 1]?.try(&.same?(block))

          accessor = Index::Accessor.from_name(node.name)
          return accessor if accessor
        end
      end
    end
  end
end
