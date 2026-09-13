require "../index/macro_target"

module Heucristic
  module Resolve
    struct Compiled
      NONE = Compiled.new(Hash(Index::MacroTarget, Set(String)).new, "", Array(String).new)

      def initialize(
        @targets : Hash(Index::MacroTarget, Set(String)),
        @root : String,
        @shim_roots : Array(String),
      ) : Nil
      end

      def project?(path : String) : Bool
        return false if @root.empty? || Index::MacroTarget.generated?(path)
        return false unless path.starts_with?(@root + "/")
        return false if path.starts_with?(File.join(@root, "lib") + "/")

        @shim_roots.none? { |shim_root| path.starts_with?(shim_root + "/") }
      end

      def known?(path : String) : Bool
        @targets.each_value.any?(&.includes?(path))
      end

      def shared?(caller_path : String, path : String) : Bool
        return true if Index::MacroTarget.generated?(path)

        @targets.each_value.any? { |files| files.includes?(caller_path) && files.includes?(path) }
      end
    end
  end
end
