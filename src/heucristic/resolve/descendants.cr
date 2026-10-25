require "../index/workspace"
require "./types"
require "./scope"
require "./resolution"

module Heucristic
  module Resolve
    class Descendants
      def initialize(@workspace : Index::Workspace, @types : Types) : Nil
        @children = nil.as(Hash(String, Array(String))?)
      end

      def invalidate : Nil
        @children = nil
      end

      def extended?(name : String) : Bool
        children.has_key?(name)
      end

      def of(name : String) : Array(String)
        found = Array(String).new
        pending = children[name]?.try(&.dup) || Array(String).new
        while (next_one = pending.pop?)
          next if found.includes?(next_one)

          found << next_one
          children[next_one]?.try { |more| pending.concat(more) }
        end
        found
      end

      private def children : Hash(String, Array(String))
        @children ||= compute_children
      end

      private def compute_children : Hash(String, Array(String))
        by_parent = Hash(String, Array(String)).new
        @workspace.each_file do |file|
          file.namespaces.each do |entry|
            next unless entry.is_a?(Index::ClassNamespace)

            parent = superclass_of(entry)
            next unless parent

            siblings = by_parent[parent] ||= Array(String).new
            siblings << entry.name unless siblings.includes?(entry.name)
          end
        end
        by_parent
      end

      private def superclass_of(entry : Index::ClassNamespace) : String?
        superclass = entry.superclass
        return unless superclass.is_a?(Syntax::Type)

        scope = Scope.new(entry.name, entry.type_vars)
        resolved = @types.resolve_lexically(superclass, scope)
        resolved.is_a?(TypeRef) ? resolved.name : nil
      end
    end
  end
end
