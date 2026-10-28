require "json"
require "./macro_site"
require "./macro_expansion"

module Heucristic
  module Index
    record MacroOutput,
      crystal : String? = nil,
      elapsed_ms : Float64? = nil,
      source : String? = nil,
      sites : Array(MacroSite) = Array(MacroSite).new,
      files : Array(String) = Array(String).new,
      expansions : Array(MacroExpansion) = Array(MacroExpansion).new,
      error : String? = nil,
      trace : String? = nil do
      include JSON::Serializable
    end
  end
end
