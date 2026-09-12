require "json"
require "../fibers"
require "../index/event"
require "../check/compiler_error"
require "./entry_file"

module Heucristic
  module Server
    class Compiler
      DEFAULT = "crystal"

      def initialize(@events : Channel(Index::Event)) : Nil
        @running = false
        @again = false
      end

      def start(root : String, executable : String?) : Nil
        if @running
          @again = true
          return
        end

        @running = true
        events = @events
        Fibers.detach(:compiler) do
          events.send(Index::CompilerStarted.new)
          events.send(check(root, executable || DEFAULT))
        end
      end

      def finished(root : String, executable : String?) : Nil
        @running = false
        return unless @again

        @again = false
        start(root, executable)
      end

      private def check(root : String, executable : String) : Index::Event
        entry = EntryFile.find(root)
        return Index::CompilerUnavailable.new(entry.reason) if entry.is_a?(EntryFile::Missing)

        run(executable, entry, root)
      end

      private def run(executable : String, entry : String, root : String) : Index::Event
        errors = IO::Memory.new
        started = Time.instant
        status = Process.run(
          executable,
          {"build", "--no-codegen", "--no-color", "--warnings", "none", "-f", "json", entry},
          chdir: root,
          output: Process::Redirect::Close,
          error: errors,
        )
        elapsed = Time.instant - started
        if status.success?
          return Index::CompilerFinished.new(Array(Check::CompilerError).new, elapsed)
        end

        report = errors.to_s
        json = report.lines.find(&.starts_with?('['))
        unless json
          first = report.lines.first?.try(&.strip) || "no output"
          return Index::CompilerFailed.new("#{executable} exited #{status.exit_code}: #{first}")
        end

        Index::CompilerFinished.new(Check::CompilerError.parse(json), elapsed)
      rescue error : JSON::ParseException
        Index::CompilerFailed.new("the compiler's output is not JSON: #{error.message}")
      rescue File::NotFoundError
        Index::CompilerUnavailable.new("#{executable} not found")
      rescue error : IO::Error | File::Error
        Index::CompilerFailed.new(error.message || error.class.name)
      end
    end
  end
end
