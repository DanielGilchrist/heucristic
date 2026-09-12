module Heucristic
  module Server
    record CompilerPending
    record CompilerDone, errors : Int32, elapsed_ms : Float64
    record CompilerBroken, reason : String
    record CompilerOff, reason : String

    alias CompilerStatus = CompilerPending | CompilerDone | CompilerBroken | CompilerOff
  end
end
