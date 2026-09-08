require "json"

module Heucristic
  module Server
    module Options
      extend self

      def stdlib?(raw : JSON::Any?) : Bool
        return true unless raw

        value = raw["stdlib"]?.try(&.as_bool?)
        value.nil? ? true : value
      end
    end
  end
end
