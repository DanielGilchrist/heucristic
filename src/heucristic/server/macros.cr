require "json"
require "../crystal_env"
require "../fibers"
require "../index/event"
require "../index/macro_output"
require "./entry_file"
require "./spec_entry"
require "../index/macro_target"
require "./semantic_helper"

module Heucristic
  module Server
    class Macros
      def initialize(@events : Channel(Index::Event)) : Nil
        @running = Hash(Index::MacroTarget, Bool).new(false)
        @again = Hash(Index::MacroTarget, Bool).new(false)
      end

      def start(root : String, configured : String?, target : Index::MacroTarget) : Nil
        if @running[target]
          @again[target] = true
          return
        end

        @running[target] = true
        events = @events
        Fibers.detach(:macros) do
          events.send(Index::MacrosStarted.new(target))
          events.send(expand(root, configured, target))
        end
      end

      def finished(root : String, configured : String?, target : Index::MacroTarget) : Nil
        @running[target] = false
        return unless @again[target]

        @again[target] = false
        start(root, configured, target)
      end

      private def expand(
        root : String,
        configured : String?,
        target : Index::MacroTarget,
      ) : Index::Event
        helper = SemanticHelper.locate(configured)
        if helper.is_a?(SemanticHelper::Missing)
          return Index::MacrosUnavailable.new(target, helper.reason)
        end

        entry = entry_for(root, target)
        return Index::MacrosUnavailable.new(target, entry.reason) unless entry.is_a?(String)

        crystal_path = CrystalEnv.crystal_path
        if crystal_path.is_a?(CrystalEnv::Unavailable)
          return Index::MacrosUnavailable.new(target, crystal_path.reason)
        end

        run(helper, entry, root, crystal_path, target)
      end

      private def entry_for(
        root : String,
        target : Index::MacroTarget,
      ) : String | EntryFile::Missing | SpecEntry::Missing
        case target
        in .main? then EntryFile.find(root)
        in .spec? then SpecEntry.find(root)
        end
      end

      private def run(
        helper : String,
        entry : String,
        root : String,
        crystal_path : String,
        target : Index::MacroTarget,
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
            target,
            "#{SemanticHelper::NAME} exited #{status.exit_code}: #{errors.to_s.lines.first?}",
          )
        end

        parsed = Index::MacroOutput.from_json(output.to_s)
        if (error = parsed.error)
          return Index::MacrosFailed.new(target, error)
        end

        source = parsed.source
        return Index::MacrosFailed.new(target, "the helper returned no source") unless source

        Index::MacrosExpanded.new(
          target, source, parsed.sites, parsed.files, Time.instant - started
        )
      rescue error : JSON::ParseException
        Index::MacrosFailed.new(target, "the helper's output is not JSON: #{error.message}")
      rescue error : IO::Error | File::Error
        Index::MacrosFailed.new(target, error.message || error.class.name)
      end
    end
  end
end
