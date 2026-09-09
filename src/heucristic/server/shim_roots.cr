require "../index/embedded_shims"
require "../log"

module Heucristic
  module Server
    module ShimRoots
      extend self

      def for(project_root : String) : Array(String)
        local = ::File.expand_path(::File.join(project_root, "shims"))
        return [local] if local == Index::EmbeddedShims::SOURCE_DIR && Dir.exists?(local)

        roots = Array(String).new
        case (embedded = Index::EmbeddedShims.materialize)
        in Disk::Unwritable
          Log.info("embedded shims unavailable: #{embedded.reason}")
        in String
          roots << embedded
        end
        roots << local if Dir.exists?(local)
        roots
      end
    end
  end
end
