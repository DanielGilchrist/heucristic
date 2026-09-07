require "uri"

module Heucristic
  module Server
    module Uri
      extend self

      record NotAFile, uri : String

      def to_path(uri : String) : String | NotAFile
        parsed = URI.parse(uri)
        return NotAFile.new(uri) unless parsed.scheme == "file"

        URI.decode(parsed.path)
      rescue URI::Error
        NotAFile.new(uri)
      end

      def from_path(path : String) : String
        URI.new(scheme: "file", host: "", path: URI.encode_path(path)).to_s
      end
    end
  end
end
