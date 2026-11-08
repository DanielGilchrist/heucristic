require "digest/sha256"
require "../version"
require "../log"
require "../disk"
require "./stale_shims"

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
        if Dir.exists?(root)
          touched = Disk.touch(root)
          Log.info("could not refresh shim cache #{root}: #{touched.reason}") if touched
        else
          placed = place(home, root)
          return placed if placed
        end

        remove_stale(home, root)
        root
      end

      private def place(home : String, root : String) : Disk::Unwritable?
        staging = "#{root}.#{Process.pid}.#{Random::Secure.hex(4)}"
        written = write_all(staging)
        if written
          Disk.remove_tree(staging)
          return written
        end

        moved = Disk.rename(staging, root)
        Disk.remove_tree(staging) if Dir.exists?(staging)
        moved
      end

      private def write_all(staging : String) : Disk::Unwritable?
        FILES.each do |(relative, contents)|
          written = Disk.write(::File.join(staging, relative), contents)
          return written if written
        end
      end

      private def remove_stale(home : String, keep : String) : Nil
        children = Disk.children(home)
        if children.is_a?(Disk::Unreadable)
          Log.info("could not list shim cache #{home}: #{children.reason}")
          return
        end

        entries = children.compact_map do |child|
          path = ::File.join(home, child)
          touched = Disk.modified_at(path)
          StaleShims::Entry.new(path, touched) if touched.is_a?(Time)
        end
        StaleShims.expired(entries, keep, Time.utc).each do |path|
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
