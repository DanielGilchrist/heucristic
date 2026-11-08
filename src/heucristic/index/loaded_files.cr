require "./macro_target"

module Heucristic
  module Index
    struct LoadedFiles
      @shim_prefixes : Array(String)

      def initialize(@files : Set(String), shim_roots : Array(String)) : Nil
        @shim_prefixes = shim_roots.map { |shim_root| shim_root + "/" }
      end

      def includes?(path : String) : Bool
        MacroTarget.generated?(path) || @files.includes?(path) ||
          @shim_prefixes.any? { |prefix| path.starts_with?(prefix) }
      end
    end
  end
end
