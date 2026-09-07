require "../fibers"
require "../log"
require "../protocol/framing"
require "../protocol/decoder"
require "../index/loader"
require "./session"

module Heucristic
  module Server
    class Loop
      alias Inbound = Protocol::Message |
                      Protocol::Unparseable |
                      Protocol::Framing::Malformed |
                      Protocol::Framing::EndOfStream

      def initialize(@input : IO, @output : IO) : Nil
        @inbound = Channel(Inbound).new(64)
        @indexed = Channel(Array(Index::File)).new(1)
        @session = Session.new(->(body : String) : Nil { send(body) })
      end

      def run : Nil
        Fibers.detach(:reader) { read_all }

        loop do
          select
          when incoming = @inbound.receive
            break if incoming.is_a?(Protocol::Framing::EndOfStream)
            break if dispatch(incoming).is_a?(Stop)
          when files = @indexed.receive
            @session.indexed(files)
          end
        end
      end

      private def read_all : Nil
        loop do
          message = Protocol::Framing.read(@input)
          incoming = message.is_a?(String) ? Protocol::Decoder.decode(message) : message
          @inbound.send(incoming)
          break if incoming.is_a?(Protocol::Framing::EndOfStream)
        end
      end

      private def dispatch(incoming : Inbound) : Outcome
        case incoming
        in Protocol::Request
          outcome = @session.handle(incoming)
          deliver(outcome)
        in Protocol::Notification
          start_indexing if incoming.method == LSProtocol::INITIALIZED
          deliver(@session.handle(incoming))
        in Protocol::Response
          deliver(@session.handle(incoming))
        in Protocol::Unparseable
          send(Protocol::Encoder.error(nil, Protocol::Encoder::PARSE_ERROR, incoming.reason))
          Silence.new
        in Protocol::Framing::Malformed
          Log.info("malformed frame: #{incoming.reason}")
          Silence.new
        in Protocol::Framing::EndOfStream
          Stop.new
        end
      end

      private def deliver(outcome : Outcome) : Outcome
        send(outcome.body) if outcome.is_a?(Reply)
        outcome
      end

      private def start_indexing : Nil
        roots = @session.index_roots
        Fibers.detach(:indexer) { @indexed.send(Index::Loader.load(roots)) }
      end

      private def send(body : String) : Nil
        written = Protocol::Framing.write(@output, body)
        return unless written.is_a?(Protocol::Framing::Disconnected)

        Log.info("client disconnected: #{written.reason}")
      end
    end
  end
end
