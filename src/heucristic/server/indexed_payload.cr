require "json"

module Heucristic
  module Server
    struct IndexedPayload
      include JSON::Serializable

      getter files : Int32
      getter shims : Int32
      getter elapsed_ms : Float64

      def initialize(@files : Int32, @shims : Int32, @elapsed_ms : Float64) : Nil
      end
    end
  end
end
