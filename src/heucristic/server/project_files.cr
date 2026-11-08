module Heucristic
  module Server
    module ProjectFiles
      def self.include?(file : String, root : String) : Bool
        path = File.expand_path(file, root)
        path.starts_with?(root + "/") && !path.starts_with?(File.join(root, "lib") + "/")
      end
    end
  end
end
