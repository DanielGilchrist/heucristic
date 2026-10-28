require "../index/macro_target"

module Heucristic
  module Resolve
    struct Compiled
      NONE = Compiled.new(Hash(Index::MacroTarget, Set(String)).new, Array(String).new)

      def initialize(
        @targets : Hash(Index::MacroTarget, Set(String)),
        @shim_roots : Array(String),
      ) : Nil
      end

      def known?(path : String) : Bool
        @targets.each_value.any?(&.includes?(path))
      end

      def loaded?(caller_path : String, path : String) : Bool
        return true unless known?(caller_path)
        return true if @shim_roots.any? { |shim_root| path.starts_with?(shim_root + "/") }

        shared?(caller_path, path)
      end

      def shared?(caller_path : String, path : String) : Bool
        return true if Index::MacroTarget.generated?(path)

        @targets.each_value.any? { |files| files.includes?(caller_path) && files.includes?(path) }
      end
    end
  end
end
