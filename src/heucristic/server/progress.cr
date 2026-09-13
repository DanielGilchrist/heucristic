require "lsprotocol"
require "../protocol/encoder"
require "../protocol/transport"
require "../index/event"

module Heucristic
  module Server
    class Progress
      TOKEN          = "heucristic/indexing"
      MACROS_TOKEN   = "heucristic/macros"
      TITLE          = "Indexing"
      COMPILER_TOKEN = "heucristic/compiler"
      COMPILER_TITLE = "Checking with the compiler"

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
            request_id, Protocol::Method::WorkDoneProgressCreate, params
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

      def begin_macros(request_id : Protocol::Id, title : String) : Nil
        begin_task(MACROS_TOKEN, title, request_id)
      end

      def finish_macros(message : String) : Nil
        finish_task(MACROS_TOKEN, message)
      end

      def begin_compiler(request_id : Protocol::Id) : Nil
        begin_task(COMPILER_TOKEN, COMPILER_TITLE, request_id)
      end

      def finish_compiler(message : String) : Nil
        finish_task(COMPILER_TOKEN, message)
      end

      private def begin_task(token : String, title : String, request_id : Protocol::Id) : Nil
        return unless @supported

        params = LSProtocol::WorkDoneProgressCreateParams.new(token: token)
        @transport.send(
          Protocol::Encoder.request(
            request_id, Protocol::Method::WorkDoneProgressCreate, params
          )
        )
        send(LSProtocol::WorkDoneProgressBegin.new(kind: "begin", title: title), token)
      end

      private def finish_task(token : String, message : String) : Nil
        return unless @supported

        send(LSProtocol::WorkDoneProgressEnd.new(kind: "end", message: message), token)
      end

      private def send(value : Value, token : String = TOKEN) : Nil
        params = {token: token, value: value}
        @transport.send(Protocol::Encoder.notification(Protocol::Method::Progress, params))
      end
    end
  end
end
