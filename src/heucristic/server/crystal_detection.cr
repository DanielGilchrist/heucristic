require "../crystal_env"
require "../crystal_version"
require "../index/shim_coverage"
require "../log"

module Heucristic
  module Server
    module CrystalDetection
      extend self

      def detect : CrystalVersion::Detected
        version = CrystalEnv.version
        case version
        in CrystalVersion::Unknown
          Log.info("Crystal version unavailable, version regions skipped: #{version.reason}")
        in CrystalVersion::Known
          Index::ShimCoverage.drift(version).try { |warning| Log.info(warning) }
        end
        version
      end
    end
  end
end
