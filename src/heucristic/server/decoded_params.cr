require "json"
require "lsprotocol"

module Heucristic
  module Server
    module DecodedParams
      extend self

      record Invalid, reason : String

      def decode(params : JSON::Any?, type : T.class) : T | Invalid forall T
        return Invalid.new("missing params") unless params

        type.from_json(params.to_json)
      rescue error : JSON::ParseException
        Invalid.new(error.message || "invalid params")
      end
    end
  end
end
