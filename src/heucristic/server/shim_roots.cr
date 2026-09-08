module Heucristic
  module Server
    module ShimRoots
      extend self

      def for(project_root : String) : Array(String)
        candidates = [::File.join(project_root, "shims")]
        if (executable = Process.executable_path)
          candidates << ::File.join(::File.dirname(::File.dirname(executable)), "shims")
        end
        candidates.map { |path| ::File.expand_path(path) }.uniq!.select { |path| Dir.exists?(path) }
      end
    end
  end
end
