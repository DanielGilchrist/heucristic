require "../fibers"
require "../log"
require "../protocol/framing"
require "../protocol/decoder"
require "../protocol/transport"
require "../index/loader"
require "./session"
require "./progress"
require "../index/event"

module Heucristic
  module Server
    class Loop
      alias Inbound = Protocol::Message |
                      Protocol::Unparseable |
                      Protocol::Framing::Malformed |
                      Protocol::Framing::EndOfStream

      def initialize(@input : IO, @output : IO) : Nil
        @inbound = Channel(Inbound).new(64)
        @events = Channel(Index::Event).new(64)
        @next_request_id = 0_i64
        @transport = Protocol::Transport.new(@output)
        @session = Session.new(@transport)
      end

      def run : Nil
        Fibers.detach(:reader) { read_all }

        loop do
          select
          when incoming = @inbound.receive
            break if incoming.is_a?(Protocol::Framing::EndOfStream)
            break if dispatch(incoming).is_a?(Stop)
          when event = @events.receive
            indexing(event)
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
          @transport.send(
            Protocol::Encoder.error(nil, Protocol::Encoder::PARSE_ERROR, incoming.reason)
          )
          Silence.new
        in Protocol::Framing::Malformed
          Log.info("malformed frame: #{incoming.reason}")
          Silence.new
        in Protocol::Framing::EndOfStream
          Stop.new
        end
      end

      private def deliver(outcome : Outcome) : Outcome
        @transport.send(outcome.body) if outcome.is_a?(Reply)
        outcome
      end

      private def start_indexing : Nil
        roots = @session.index_roots
        shim_roots = @session.shim_roots
        events = @events
        Fibers.detach(:indexer) { Index::Loader.load(roots, shim_roots, events) }
      end

      private def indexing(event : Index::Event) : Nil
        case event
        in Index::Started
          @next_request_id += 1
          @session.progress.begin(event, @next_request_id)
        in Index::Advanced then @session.progress.advance(event)
        in Index::Finished
          @session.progress.finish(event)
          @session.indexed(event)
        end
      end
    end
  end
end
