require "json"
require "./message"

module Heucristic
  module Protocol
    module Encoder
      extend self

      PARSE_ERROR      = -32700
      INVALID_REQUEST  = -32600
      METHOD_NOT_FOUND = -32601
      INVALID_PARAMS   = -32602
      INTERNAL_ERROR   = -32603
      CONTENT_MODIFIED = -32801

      def result(id : Id, result : T) : String forall T
        JSON.build do |json|
          json.object do
            json.field "jsonrpc", "2.0"
            json.field "id", id
            json.field("result") { result.to_json(json) }
          end
        end
      end

      def error(id : Id?, code : Int32, message : String) : String
        JSON.build do |json|
          json.object do
            json.field "jsonrpc", "2.0"
            json.field "id", id
            json.field "error" do
              json.object do
                json.field "code", code
                json.field "message", message
              end
            end
          end
        end
      end

      def notification(method : String, params : T) : String forall T
        JSON.build do |json|
          json.object do
            json.field "jsonrpc", "2.0"
            json.field "method", method
            json.field("params") { params.to_json(json) }
          end
        end
      end
    end
  end
end
