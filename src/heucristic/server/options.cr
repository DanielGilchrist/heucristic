require "json"

module Heucristic
  module Server
    module Options
      extend self

      def semantic(raw : JSON::Any?) : String?
        field(raw, "semantic").try(&.as_s?)
      end

      def compiler(raw : JSON::Any?) : String?
        field(raw, "compiler").try(&.as_s?)
      end

      def defines(raw : JSON::Any?) : Array(String)
        listed = field(raw, "defines").try(&.as_a?)
        return Array(String).new unless listed

        listed.compact_map(&.as_s?)
      end

      def stdlib?(raw : JSON::Any?) : Bool
        value = field(raw, "stdlib").try(&.as_bool?)
        value.nil? ? true : value
      end

      private def field(raw : JSON::Any?, name : String) : JSON::Any?
        raw.try(&.as_h?).try(&.[name]?)
      end
    end
  end
end
