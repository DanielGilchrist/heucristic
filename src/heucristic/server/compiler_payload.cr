require "json"
require "./stage"

module Heucristic
  module Server
    @[JSON::Serializable::Options(emit_nulls: true)]
    struct CompilerPayload
      include JSON::Serializable

      getter status : Stage
      getter errors : Int32
      getter elapsed_ms : Float64
      getter reason : String?
      getter file : String?
      getter line : Int32?
      getter message : String?

      def initialize(
        @status : Stage,
        @errors : Int32,
        @elapsed_ms : Float64,
        @reason : String?,
        @file : String?,
        @line : Int32?,
        @message : String?,
      ) : Nil
      end
    end
  end
end
