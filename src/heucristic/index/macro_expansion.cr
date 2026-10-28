require "json"

module Heucristic
  module Index
    record MacroExpansion,
      path : String,
      line : Int32,
      column : Int32,
      name : String,
      source : String do
      include JSON::Serializable

      record Key, path : String, line : Int32, column : Int32

      def key : Key
        Key.new(path, line, column)
      end
    end
  end
end
