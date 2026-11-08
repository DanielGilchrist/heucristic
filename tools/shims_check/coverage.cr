require "../../src/heucristic/crystal_version"

module ShimsCheck
  module Coverage
    extend self

    SOURCE = File.expand_path("../../src/heucristic/index/shim_coverage.cr", __DIR__)

    def stamp(version : Heucristic::CrystalVersion::Known) : Nil
      text = File.read(SOURCE)
      updated = text.sub(/CHECKED = "[^"]*"/, %(CHECKED = "#{version.value}"))
      File.write(SOURCE, updated) unless updated == text
    end
  end
end
