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
      build(
        line, owner, item.definition.name, item.metaclass, item.file,
        item.origin || real_location(item.file.expanded_location), private_to
      )
    end

    def self.declaring(
      line : Int32,
      type : Crystal::Type,
      file : Crystal::VirtualFile,
      private_to : String?,
    ) : Heucristic::Index::MacroSite
      expanded = real_location(file.expanded_location)
      build(line, type.to_s, file.macro.name, false, file, expanded, private_to)
    end

    def self.build(
      line : Int32,
      owner : String,
      name : String,
      metaclass : Bool,
      file : Crystal::VirtualFile,
      expanded : Crystal::Location?,
      private_to : String?,
    ) : Heucristic::Index::MacroSite
      macro_location = file.macro.location
      Heucristic::Index::MacroSite.new(
        line,
        owner,
        name,
        metaclass,
        file.macro.name,
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
