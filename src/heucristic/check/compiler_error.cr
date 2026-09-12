require "json"

module Heucristic
  module Check
    record CompilerError,
      file : String,
      line : Int32?,
      column : Int32,
      size : Int32,
      message : String do
      include JSON::Serializable

      def self.parse(raw : String) : Array(CompilerError)
        Array(CompilerError).from_json(raw)
      end
    end
  end
end
