require "../index/owner"

module Heucristic
  module Resolve
    record Scope, namespace : Index::Owner, type_vars : Array(String) do
      TOP = new(Index::TopLevel.new, Array(String).new)

      def self.of(namespace : String) : Scope
        new(namespace, Array(String).new)
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
