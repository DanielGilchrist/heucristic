require "../crystal_version"

module Heucristic
  module Index
    module ShimCoverage
      CHECKED = "1.22.2"

      def self.drift(installed : CrystalVersion::Detected) : String?
        case installed
        in CrystalVersion::Unknown then return
        in CrystalVersion::Known   then nil
        end

        checked = CrystalVersion.parse(CHECKED)
        return unless checked.is_a?(CrystalVersion::Known)
        return if checked.value.major == installed.value.major &&
                  checked.value.minor == installed.value.minor

        "shims were checked against Crystal #{CHECKED}, this project uses #{installed.value}; " \
        "stdlib return types may differ"
      end
    end
  end
end
