require "./file"
require "./macro_site"
require "./sites"

module Heucristic
  module Index
    record Started, total : Int32
    record Advanced, done : Int32, total : Int32
    record Finished,
      files : Array(File),
      shims : Array(File),
      sites : Array(Sites),
      elapsed : Time::Span
    record MacrosStarted
    record MacrosExpanded, source : String, sites : Array(MacroSite), elapsed : Time::Span
    record MacrosFailed, reason : String
    record MacrosUnavailable, reason : String

    alias Event = Started | Advanced | Finished |
                  MacrosStarted | MacrosExpanded | MacrosFailed | MacrosUnavailable
  end
end
