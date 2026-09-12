require "./file"
require "./macro_site"
require "./sites"
require "../check/compiler_error"

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
    record MacrosExpanded,
      source : String,
      sites : Array(MacroSite),
      files : Array(String),
      elapsed : Time::Span
    record MacrosFailed, reason : String
    record MacrosUnavailable, reason : String
    record CompilerStarted
    record CompilerFinished, errors : Array(Check::CompilerError), elapsed : Time::Span
    record CompilerFailed, reason : String
    record CompilerUnavailable, reason : String

    alias Event = Started | Advanced | Finished |
                  MacrosStarted | MacrosExpanded | MacrosFailed | MacrosUnavailable |
                  CompilerStarted | CompilerFinished | CompilerFailed | CompilerUnavailable
  end
end
