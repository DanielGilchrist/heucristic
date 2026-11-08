require "compiler/crystal/syntax"
require "../index/owner"
require "../index/accessor"
require "./well_known"

module Heucristic
  module Syntax
    record Context,
      enclosing : Array(Index::Identity),
      type_vars : Array(String),
      def_node : Crystal::Def?,
      blocks : Array(Crystal::Call),
      ancestors : Array(Crystal::ASTNode),
      path : String? = nil,
      instance : Bool = false do
      def self.new(
        enclosing : Array(Index::Identity),
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

      def same_as?(other : Context) : Bool
        return false unless path == other.path && instance == other.instance
        return false unless def_node.same?(other.def_node)

        enclosing == other.enclosing && type_vars == other.type_vars &&
          same_nodes?(blocks, other.blocks) && same_nodes?(ancestors, other.ancestors)
      end

      def copy : Context
        Context.new(
          enclosing.dup, type_vars.dup, def_node, blocks.dup, ancestors.dup, path, instance
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

      def in_pending? : Bool
        blocks.any? do |block_call|
          block_call.obj.nil? && WellKnown::Pending.named?(block_call.name)
        end
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

      private def same_nodes?(left : Array(T), right : Array(T)) : Bool forall T
        return false unless left.size == right.size

        left.each_with_index { |node, index| return false unless node.same?(right[index]) }
        true
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
