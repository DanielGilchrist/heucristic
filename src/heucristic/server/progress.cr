require "lsprotocol"
require "../protocol/encoder"
require "../protocol/transport"
require "../index/event"

module Heucristic
  module Server
    class Progress
      TOKEN = "heucristic/indexing"
      TITLE = "Indexing"

      alias Value = LSProtocol::WorkDoneProgressBegin |
                    LSProtocol::WorkDoneProgressReport |
                    LSProtocol::WorkDoneProgressEnd

      def initialize(@transport : Protocol::Transport, @supported : Bool) : Nil
        @reported = 0
      end

      def begin(event : Index::Started, request_id : Protocol::Id) : Nil
        return unless @supported

        @reported = 0
        params = LSProtocol::WorkDoneProgressCreateParams.new(token: TOKEN)
        @transport.send(
          Protocol::Encoder.request(
            request_id, LSProtocol::WINDOW_WORK_DONE_PROGRESS_CREATE, params
          )
        )
        send(LSProtocol::WorkDoneProgressBegin.new(
          kind: "begin", title: TITLE, message: "0/#{event.total} files", percentage: 0_u32
        ))
      end

      def advance(event : Index::Advanced) : Nil
        return unless @supported

        percentage = event.total.zero? ? 100 : event.done * 100 // event.total
        return if percentage == @reported

        @reported = percentage
        send(LSProtocol::WorkDoneProgressReport.new(
          kind: "report",
          message: "#{event.done}/#{event.total} files",
          percentage: percentage.to_u32,
        ))
      end

      def finish(event : Index::Finished) : Nil
        return unless @supported

        send(LSProtocol::WorkDoneProgressEnd.new(
          kind: "end",
          message: "#{event.files.size} files in #{event.elapsed.total_milliseconds.round}ms",
        ))
      end

      private def send(value : Value) : Nil
        params = {token: TOKEN, value: value}
        @transport.send(Protocol::Encoder.notification(LSProtocol::PROGRESS, params))
      end
    end
  end
end
