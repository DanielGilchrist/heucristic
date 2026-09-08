module Heucristic
  module Resolve
    record Scope, namespace : String, type_vars : Array(String) do
      TOP = new("", Array(String).new)

      def self.of(namespace : String) : Scope
        new(namespace, Array(String).new)
      end

      def chain : Array(String)
        chain = Array(String).new
        current = namespace
        until current.empty?
          chain << current
          current = current.rpartition("::")[0]
        end
        chain << ""
        chain
      end
    end
  end
end
