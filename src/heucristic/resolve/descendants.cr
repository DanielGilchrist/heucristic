require "../index/workspace"
require "./types"
require "./scope"
require "./resolution"
require "./builtins"

module Heucristic
  module Resolve
    class Descendants
      @children : Hash(Index::Identity, Array(Index::Identity))? = nil

      def initialize(@workspace : Index::Workspace, @types : Types) : Nil
        @below = Hash(Index::Identity, Array(Index::Identity)).new
      end

      def invalidate : Nil
        @children = nil
        @below.clear
      end

      def extended?(identity : Index::Identity) : Bool
        children.has_key?(identity)
      end

      def of(identity : Index::Identity) : Array(Index::Identity)
        @below[identity] ||= collect(identity)
      end

      private def collect(identity : Index::Identity) : Array(Index::Identity)
        found = Array(Index::Identity).new
        pending = children[identity]?.try(&.dup) || Array(Index::Identity).new
        while (next_one = pending.pop?)
          next if found.includes?(next_one)

          found << next_one
          children[next_one]?.try { |more| pending.concat(more) }
        end
        found.sort_by!(&.name)
      end

      private def children : Hash(Index::Identity, Array(Index::Identity))
        @children ||= compute_children
      end

      private def compute_children : Hash(Index::Identity, Array(Index::Identity))
        by_parent = Hash(Index::Identity, Array(Index::Identity)).new
        Builtins::SUPERCLASSES.each do |child, parent|
          siblings = by_parent[Index::Public.new(parent)] ||= Array(Index::Identity).new
          siblings << Index::Public.new(child)
        end
        @workspace.each_file do |file|
          file.namespaces.each do |entry|
            next unless entry.is_a?(Index::ClassNamespace)

            parent = superclass_of(entry)
            next unless parent

            siblings = by_parent[parent] ||= Array(Index::Identity).new
            siblings << entry.identity unless siblings.includes?(entry.identity)
          end
        end
        by_parent
      end

      private def superclass_of(entry : Index::ClassNamespace) : Index::Identity?
        superclass = entry.superclass
        return unless superclass.is_a?(Syntax::Type)

        scope = Scope.new(entry.identity, entry.type_vars).at(entry.path)
        resolved = @types.resolve_lexically(superclass, scope)
        resolved.is_a?(TypeRef) ? resolved.identity : nil
      end
    end
  end
end
