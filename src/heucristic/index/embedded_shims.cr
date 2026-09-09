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

      def materialize : String | Disk::Unwritable
        root = ::File.join(cache_home, "heucristic", VERSION, "shims")
        FILES.each do |(relative, contents)|
          path = ::File.join(root, relative)
          next if current?(path, contents)

          written = Disk.write(path, contents)
          return written if written.is_a?(Disk::Unwritable)
        end
        root
      end

      private def current?(path : String, contents : String) : Bool
        existing = Disk.read(path)
        existing.is_a?(String) && existing == contents
      end

      private def cache_home : String
        ENV["XDG_CACHE_HOME"]? || ::File.join(Path.home.to_s, ".cache")
      end
    end
  end
end
