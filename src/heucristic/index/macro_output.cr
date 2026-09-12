require "json"
require "./macro_site"

module Heucristic
  module Index
    record MacroOutput,
      crystal : String? = nil,
      elapsed_ms : Float64? = nil,
      source : String? = nil,
      sites : Array(MacroSite) = Array(MacroSite).new,
      files : Array(String) = Array(String).new,
      error : String? = nil,
      trace : String? = nil do
      include JSON::Serializable
    end
  end
end
