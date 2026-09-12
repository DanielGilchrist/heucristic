require "json"
require "../crystal_env"
require "../fibers"
require "../index/event"
require "../index/macro_output"
require "./entry_file"
require "./semantic_helper"

module Heucristic
  module Server
    class Macros
      def initialize(@events : Channel(Index::Event)) : Nil
        @running = false
        @again = false
      end

      def start(root : String, configured : String?) : Nil
        if @running
          @again = true
          return
        end

        @running = true
        events = @events
        Fibers.detach(:macros) do
          events.send(Index::MacrosStarted.new)
          events.send(expand(root, configured))
        end
      end

      def finished(root : String, configured : String?) : Nil
        @running = false
        return unless @again

        @again = false
        start(root, configured)
      end

      private def expand(root : String, configured : String?) : Index::Event
        helper = SemanticHelper.locate(configured)
        return Index::MacrosUnavailable.new(helper.reason) if helper.is_a?(SemanticHelper::Missing)

        entry = EntryFile.find(root)
        return Index::MacrosUnavailable.new(entry.reason) if entry.is_a?(EntryFile::Missing)

        crystal_path = CrystalEnv.crystal_path
        if crystal_path.is_a?(CrystalEnv::Unavailable)
          return Index::MacrosUnavailable.new(crystal_path.reason)
        end

        run(helper, entry, root, crystal_path)
      end

      private def run(
        helper : String,
        entry : String,
        root : String,
        crystal_path : String,
      ) : Index::Event
        output = IO::Memory.new
        errors = IO::Memory.new
        started = Time.instant
        status = Process.run(
          helper,
          {entry, root},
          env: {"CRYSTAL_PATH" => crystal_path},
          chdir: root,
          output: output,
          error: errors,
        )
        unless status.success?
          return Index::MacrosFailed.new(
            "#{SemanticHelper::NAME} exited #{status.exit_code}: #{errors.to_s.lines.first?}"
          )
        end

        parsed = Index::MacroOutput.from_json(output.to_s)
        if (error = parsed.error)
          return Index::MacrosFailed.new(error)
        end

        source = parsed.source
        return Index::MacrosFailed.new("the helper returned no source") unless source

        Index::MacrosExpanded.new(source, parsed.sites, parsed.files, Time.instant - started)
      rescue error : JSON::ParseException
        Index::MacrosFailed.new("the helper's output is not JSON: #{error.message}")
      rescue error : IO::Error | File::Error
        Index::MacrosFailed.new(error.message || error.class.name)
      end
    end
  end
end
