require "compiler/requires"
require "json"
require "./generated"

module Semantic
  record Site,
    line : Int32,
    owner : String,
    name : String,
    metaclass : Bool,
    macro_name : String,
    macro_path : String?,
    macro_line : Int32?,
    expanded_path : String?,
    expanded_line : Int32?,
    expanded_column : Int32? do
    include JSON::Serializable

    def self.of(line : Int32, owner : String, item : Generated) : Site
      macro_location = item.file.macro.location
      expanded = real_location(item.file.expanded_location)
      new(
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
