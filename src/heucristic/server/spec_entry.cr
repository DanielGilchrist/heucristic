require "./cache_entry"

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

        written = CacheEntry.write("spec", root, "require \"spec\"\n", files)
        written.is_a?(CacheEntry::Missing) ? Missing.new(written.reason) : written
      end
    end
  end
end
