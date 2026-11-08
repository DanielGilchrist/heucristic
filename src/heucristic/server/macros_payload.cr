require "json"
require "../index/macro_target"
require "./stage"

module Heucristic
  module Server
    @[JSON::Serializable::Options(emit_nulls: true)]
    struct MacrosPayload
      include JSON::Serializable

      getter status : Stage
      getter defs : Int32
      getter elapsed_ms : Float64
      getter reason : String?
      getter target : Index::MacroTarget

      def initialize(
        @status : Stage,
        @defs : Int32,
        @elapsed_ms : Float64,
        @reason : String?,
        @target : Index::MacroTarget,
      ) : Nil
      end
    end
  end
end
