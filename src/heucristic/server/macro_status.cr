module Heucristic
  module Server
    record MacrosPending
    record MacrosDone, defs : Int32, elapsed_ms : Float64, note : String?
    record MacrosStale, reason : String, defs : Int32
    record MacrosOff, reason : String

    alias MacroStatus = MacrosPending | MacrosDone | MacrosStale | MacrosOff
  end
end
