require "../protocol/encoder"
require "../protocol/transport"
require "../index/event"
require "../check/compiler_error"
require "./compiler"
require "./compiler_status"
require "./diagnostics"
require "./notice"
require "./open_documents"
require "./project_files"
require "./published"
require "./stage"
require "./uri"

module Heucristic
  module Server
    class CompilerState
      def initialize(
        events : Channel(Index::Event),
        @transport : Protocol::Transport,
        @documents : OpenDocuments,
      ) : Nil
        @compiler = Compiler.new(events)
        @status = CompilerPending.new
      end

      def defines(flags : Array(String)) : Nil
        @compiler.defines(flags)
      end

      def start(root : String, executable : String?) : Nil
        @compiler.start(root, executable)
      end

      def started : Nil
        @status = CompilerPending.new
        notify
      end

      def finished(
        event : Index::CompilerFinished,
        root : String,
        executable : String?,
        & : Published::Batch ->
      ) : Nil
        frame = placed_frame(event.errors, root)
        batch = batch_of(frame, root)
        yield batch
        @status = CompilerDone.new(
          batch.size,
          event.elapsed.total_milliseconds.round,
          frame.try { |found| File.expand_path(found.file, root) },
          frame.try(&.line),
          frame.try(&.message),
        )
        notify
        @compiler.finished(root, executable)
      end

      def failed(event : Index::CompilerFailed, root : String, executable : String?) : Nil
        @status = CompilerBroken.new(event.reason)
        notify
        @compiler.finished(root, executable)
      end

      def unavailable(
        event : Index::CompilerUnavailable,
        root : String,
        executable : String?,
      ) : Nil
        @status = CompilerOff.new(event.reason)
        notify
        @compiler.finished(root, executable)
      end

      private def notify : Nil
        @transport.send(Protocol::Encoder.notification(Notice::Compiler.method, @status.payload))
      end

      private def placed_frame(
        errors : Array(Check::CompilerError),
        root : String,
      ) : Check::CompilerError?
        last = errors.last?
        return unless last

        failing = errors.select do |error|
          ProjectFiles.include?(error.file, root) && error.message == last.message
        end
        failing.first? ||
          errors.reverse.find { |error| ProjectFiles.include?(error.file, root) } || last
      end

      private def batch_of(frame : Check::CompilerError?, root : String) : Published::Batch
        batch = Published::Batch.new
        return batch unless frame

        path = File.expand_path(frame.file, root)
        uri = Uri.from_path(path)
        batch[uri] = [Diagnostics.compiler(frame, @documents.text(path))]
        batch
      end
    end
  end
end
