module Heucristic
  module Server
    module SemanticHelper
      extend self

      record Missing, reason : String

      NAME = "heucristic-semantic"

      def locate(configured : String?) : String | Missing
        if configured
          return configured if executable?(configured)

          return Missing.new("#{configured} is not an executable file")
        end

        executable = Process.executable_path
        return Missing.new("the server's own path is unknown") unless executable

        sibling = File.join(File.dirname(executable), NAME)
        return sibling if executable?(sibling)

        Missing.new("#{sibling} is not built; run script/build-semantic")
      end

      private def executable?(path : String) : Bool
        info = ::File.info?(path)
        return false unless info

        info.file? && info.permissions.owner_execute?
      end
    end
  end
end
