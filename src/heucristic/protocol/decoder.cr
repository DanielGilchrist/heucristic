require "json"
require "./message"
require "./unparseable"

module Heucristic
  module Protocol
    module Decoder
      extend self

      def decode(body : String) : Message | Unparseable
        raw = parse_json(body)
        return raw if raw.is_a?(Unparseable)

        object = raw.as_h?
        return Unparseable.new("message is not an object") unless object

        id = decode_id(object["id"]?)
        return id if id.is_a?(Unparseable)

        method = object["method"]?.try(&.as_s?)
        params = object["params"]?

        if method
          id ? Request.new(id, method, params) : Notification.new(method, params)
        else
          Response.new(id, object["result"]?, object["error"]?)
        end
      end

      private def parse_json(body : String) : JSON::Any | Unparseable
        JSON.parse(body)
      rescue error : JSON::ParseException
        Unparseable.new(error.message || "invalid json")
      end

      private def decode_id(raw : JSON::Any?) : Id | Nil | Unparseable
        return if raw.nil? || raw.raw.nil?

        raw.as_i64? || raw.as_s? || Unparseable.new("id must be an integer or string")
      end
    end
  end
end
