require "../log"
require "./framing"

module Heucristic
  module Protocol
    class Transport
      def initialize(@output : IO) : Nil
        @lock = Mutex.new
      end

      def send(body : String) : Nil
        written = @lock.synchronize { Framing.write(@output, body) }
        return unless written.is_a?(Framing::Disconnected)

        Log.info("client disconnected: #{written.reason}")
      end
    end
  end
end
