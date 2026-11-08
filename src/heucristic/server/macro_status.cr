require "./macros_payload"

module Heucristic
  module Server
    record MacrosPending do
      def payload : MacrosPayload
        MacrosPayload.new(:pending, 0, 0.0, nil, :main)
      end
    end

    record MacrosDone, defs : Int32, elapsed_ms : Float64, note : String? do
      def payload : MacrosPayload
        MacrosPayload.new(:done, defs, elapsed_ms, note, :main)
      end
    end

    record MacrosStale, reason : String, defs : Int32 do
      def payload : MacrosPayload
        MacrosPayload.new(:stale, defs, 0.0, reason, :main)
      end
    end

    record MacrosOff, reason : String do
      def payload : MacrosPayload
        MacrosPayload.new(:unavailable, 0, 0.0, reason, :main)
      end
    end

    alias MacroStatus = MacrosPending | MacrosDone | MacrosStale | MacrosOff
  end
end
