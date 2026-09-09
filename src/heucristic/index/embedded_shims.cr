require "digest/sha256"
require "../version"
require "../log"
require "../disk"

module Heucristic
  module Index
    module EmbeddedShims
      extend self

      SOURCE_DIR = ::File.expand_path("#{__DIR__}/../../../shims")

      {% begin %}
        {% listing = "cd #{__DIR__}/../../../shims && find . -name '*.cr' | cut -c3- | sort" %}
        FILES = {
          {% for path in system(listing).lines %}
            { {{ path.strip }}, {{ read_file("#{__DIR__}/../../../shims/#{path.strip.id}") }} },
          {% end %}
        }
      {% end %}

      def digest : String
        Digest::SHA256.hexdigest do |sha|
          FILES.each do |(relative, contents)|
            sha << relative << "\0" << contents << "\0"
          end
        end[0, 16]
      end

      def materialize : String | Disk::Unwritable
        home = ::File.join(cache_home, "heucristic", "shims")
        root = ::File.join(home, digest)
        return root if Dir.exists?(root)

        staging = "#{root}.#{Process.pid}"
        FILES.each do |(relative, contents)|
          written = Disk.write(::File.join(staging, relative), contents)
          return written if written.is_a?(Disk::Unwritable)
        end
        moved = Disk.rename(staging, root)
        return moved if moved.is_a?(Disk::Unwritable)

        remove_stale(home, root)
        root
      end

      private def remove_stale(home : String, keep : String) : Nil
        Dir.children(home).each do |child|
          path = ::File.join(home, child)
          next if path == keep

          removed = Disk.remove_tree(path)
          Log.info("could not remove old shim cache #{path}: #{removed.reason}") if removed
        end
      end

      private def cache_home : String
        ENV["XDG_CACHE_HOME"]? || ::File.join(Path.home.to_s, ".cache")
      end
    end
  end
end
