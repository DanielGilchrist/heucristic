require "../index/owner"
require "../syntax/context"
require "./binding"

module Heucristic
  module Resolve
    record Scope,
      namespace : Index::Owner,
      type_vars : Array(String),
      bindings : Array(Binding),
      path : String? = nil do
      TOP = new(Index::TopLevel.new, Array(String).new, Array(Binding).new)

      def self.new(namespace : Index::Owner, type_vars : Array(String)) : Scope
        new(namespace, type_vars, Array(Binding).new)
      end

      def self.of(namespace : Index::Owner, path : String? = nil) : Scope
        new(namespace, Array(String).new, Array(Binding).new, path)
      end

      def self.of(context : Syntax::Context) : Scope
        new(context.owner, context.type_vars, Array(Binding).new, context.path)
      end

      def at(path : String?) : Scope
        copy_with(path: path)
      end

      def bound(name : String) : Resolution?
        bindings.find(&.name.==(name)).try(&.value)
      end

      def chain : Array(Index::Owner)
        chain = Array(Index::Owner).new
        current = namespace
        while current.is_a?(Index::Identity)
          chain << current
          current = current.parent
        end
        chain << Index::TopLevel.new
        chain
      end
    end
  end
end
