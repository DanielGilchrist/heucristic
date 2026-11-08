require "compiler/requires"
require "../../src/heucristic/index/macro_site"
require "./generated"

module Semantic
  module Sites
    def self.of(
      line : Int32,
      owner : String,
      item : Generated,
      private_to : String?,
    ) : Heucristic::Index::MacroSite
      macro_location = item.file.macro.location
      expanded = item.origin || real_location(item.file.expanded_location)
      Heucristic::Index::MacroSite.new(
        line,
        owner,
        item.definition.name,
        item.metaclass,
        item.file.macro.name,
        macro_location.try(&.original_filename),
        macro_location.try(&.line_number),
        expanded.try(&.original_filename),
        expanded.try(&.line_number),
        expanded.try(&.column_number),
        private_to,
      )
    end

    def self.real_location(location : Crystal::Location?) : Crystal::Location?
      while location && (filename = location.filename).is_a?(Crystal::VirtualFile)
        location = filename.expanded_location
      end
      location
    end
  end
end
