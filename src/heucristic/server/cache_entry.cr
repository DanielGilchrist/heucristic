require "digest/sha256"
require "../disk"

module Heucristic
  module Server
    module CacheEntry
      extend self

      record Missing, reason : String

      def write(
        kind : String,
        root : String,
        preamble : String,
        files : Array(String),
      ) : String | Missing
        path = File.join(cache_home, "heucristic", kind, "#{Digest::SHA256.hexdigest(root)}.cr")
        directory = Path[File.dirname(path)]
        source = String.build do |io|
          io << preamble
          files.each do |file|
            relative = Path[file.rchop(".cr")].relative_to(directory).to_s
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
