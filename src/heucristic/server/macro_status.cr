require "../index/exclusions"

module Heucristic
  module Server
    record MacrosPending
    record MacrosDone, defs : Int32, elapsed_ms : Float64, excluded : Index::Exclusions
    record MacrosStale, reason : String, defs : Int32
    record MacrosOff, reason : String

    alias MacroStatus = MacrosPending | MacrosDone | MacrosStale | MacrosOff
  end
end
