require "./compiler_payload"

module Heucristic
  module Server
    record CompilerPending do
      def payload : CompilerPayload
        CompilerPayload.new(:pending, 0, 0.0, nil, nil, nil, nil)
      end
    end

    record CompilerDone,
      errors : Int32,
      elapsed_ms : Float64,
      file : String?,
      line : Int32?,
      message : String? do
      def payload : CompilerPayload
        CompilerPayload.new(:done, errors, elapsed_ms, nil, file, line, message)
      end
    end

    record CompilerBroken, reason : String do
      def payload : CompilerPayload
        CompilerPayload.new(:failed, 0, 0.0, reason, nil, nil, nil)
      end
    end

    record CompilerOff, reason : String do
      def payload : CompilerPayload
        CompilerPayload.new(:unavailable, 0, 0.0, reason, nil, nil, nil)
      end
    end

    alias CompilerStatus = CompilerPending | CompilerDone | CompilerBroken | CompilerOff
  end
end
