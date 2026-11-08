require "semantic_version"

module Heucristic
  module CrystalVersion
    record Known, value : SemanticVersion
    record Unknown, reason : String

    alias Detected = Known | Unknown

    def self.parse(raw : String) : Detected
      Known.new(SemanticVersion.parse(raw.strip))
    rescue error : ArgumentError
      Unknown.new("unparseable Crystal version #{raw.inspect}: #{error.message}")
    end
  end
end
