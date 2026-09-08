require "../index/owner"
require "./binding"

module Heucristic
  module Resolve
    record Scope, namespace : Index::Owner, type_vars : Array(String), bindings : Array(Binding) do
      TOP = new(Index::TopLevel.new, Array(String).new, Array(Binding).new)

      def self.new(namespace : Index::Owner, type_vars : Array(String)) : Scope
        new(namespace, type_vars, Array(Binding).new)
      end

      def self.of(namespace : String) : Scope
        new(namespace, Array(String).new, Array(Binding).new)
      end

      def bound(name : String) : Resolution?
        bindings.find(&.name.==(name)).try(&.value)
      end

      def chain : Array(Index::Owner)
        chain = Array(Index::Owner).new
        current = namespace
        while current.is_a?(String)
          chain << current
          parent = current.rpartition("::")[0]
          current = parent.empty? ? Index::TopLevel.new : parent
        end
        chain << Index::TopLevel.new
        chain
      end
    end
  end
end
