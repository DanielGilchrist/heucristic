require "./cache_entry"

module Heucristic
  module Server
    module LooseEntry
      extend self

      record Missing, reason : String

      def find(root : String, files : Array(String)) : String | Missing
        return Missing.new("no open file outside the compiled targets") if files.empty?

        written = CacheEntry.write("loose", root, "", files.sort)
        written.is_a?(CacheEntry::Missing) ? Missing.new(written.reason) : written
      end
    end
  end
end
