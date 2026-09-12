require "json"

module Heucristic
  module Server
    module Options
      extend self

      def semantic(raw : JSON::Any?) : String?
        raw.try(&.["semantic"]?).try(&.as_s?)
      end

      def compiler(raw : JSON::Any?) : String?
        raw.try(&.["compiler"]?).try(&.as_s?)
      end

      def stdlib?(raw : JSON::Any?) : Bool
        return true unless raw

        value = raw["stdlib"]?.try(&.as_bool?)
        value.nil? ? true : value
      end
    end
  end
end
