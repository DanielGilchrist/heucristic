require "../crystal_env"
require "../log"

module Heucristic
  module Server
    class SourcePaths
      @paths : Array(String)?

      def initialize : Nil
        @paths = nil
      end

      def paths(root : String) : Array(String)
        @paths ||= case (found = CrystalEnv.source_paths(root))
                   in CrystalEnv::Unavailable
                     Log.info("crystal source paths unavailable: #{found.reason}")
                     Array(String).new
                   in Array(String)
                     found
                   end
      end
    end
  end
end
