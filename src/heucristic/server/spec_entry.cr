require "digest/sha256"
require "../disk"

module Heucristic
  module Server
    module SpecEntry
      extend self

      record Missing, reason : String

      def find(root : String) : String | Missing
        directory = File.join(root, "spec")
        return Missing.new("no spec directory in #{root}") unless Dir.exists?(directory)

        files = Dir.glob(File.join(directory, "**", "*_spec.cr")).sort!
        return Missing.new("no spec files in #{directory}") if files.empty?

        path = File.join(cache_home, "heucristic", "spec", "#{Digest::SHA256.hexdigest(root)}.cr")
        source = String.build do |io|
          io << "require \"spec\"\n"
          files.each do |file|
            relative = Path[file.rchop(".cr")].relative_to(Path[File.dirname(path)]).to_s
            io << "require " << relative.inspect << '\n'
          end
        end
        written = Disk.write(path, source)
        return Missing.new("#{written.path}: #{written.reason}") if written

        path
      end

      private def cache_home : String
        ENV["XDG_CACHE_HOME"]? || File.join(Path.home.to_s, ".cache")
      end
    end
  end
end
