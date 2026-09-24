require "json"
require "../crystal_env"
require "../fibers"
require "../index/event"
require "../index/macro_output"
require "./entry_file"
require "./cache_entry"
require "./spec_entry"
require "./loose_entry"
require "../index/macro_target"
require "./semantic_helper"

module Heucristic
  module Server
    class Macros
      alias Missing = EntryFile::Missing |
                      SpecEntry::Missing |
                      LooseEntry::Missing |
                      CacheEntry::Missing

      def initialize(@events : Channel(Index::Event)) : Nil
        @running = Hash(Index::MacroTarget, Bool).new(false)
        @again = Hash(Index::MacroTarget, Bool).new(false)
        @loose = Array(String).new
        @excluded = Hash(Index::MacroTarget, Hash(String, String)).new
        @defines = Array(String).new
      end

      def defines(flags : Array(String)) : Nil
        @defines = flags
      end

      def loose(files : Array(String)) : Nil
        @loose = files
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

        crystal_path = CrystalEnv.crystal_path
        if crystal_path.is_a?(CrystalEnv::Unavailable)
          return Index::MacrosUnavailable.new(target, crystal_path.reason)
        end

        loop do
          entry = entry_for(root, target)
          return Index::MacrosUnavailable.new(target, entry.reason) unless entry.is_a?(String)

          event = run(helper, entry, root, crystal_path, target)
          return event unless event.is_a?(Index::MacrosFailed)

          culprit = culprit(entry, event.trace, candidates(root, target), root)
          return event unless culprit

          excluded(target)[culprit] = failure_line(event.trace, event.reason)
        end
      end

      private def entry_for(
        root : String,
        target : Index::MacroTarget,
      ) : String | Missing
        case target
        in .spec? then SpecEntry.find(root)
        in .main?
          mains = EntryFile.mains(root)
          return mains if mains.is_a?(EntryFile::Missing)

          remaining = remaining(target, mains)
          remaining.size == 1 ? remaining.first : CacheEntry.write("main", root, "", remaining)
        in .loose?
          LooseEntry.find(root, remaining(target, @loose))
        end
      end

      private def remaining(target : Index::MacroTarget, files : Array(String)) : Array(String)
        left = excluded(target)
        files.reject { |file| left.has_key?(file) }
      end

      private def excluded(target : Index::MacroTarget) : Hash(String, String)
        @excluded[target] ||= Hash(String, String).new
      end

      private def candidates(root : String, target : Index::MacroTarget) : Array(String)
        listed = case target
                 in .spec? then Array(String).new
                 in .main?
                   mains = EntryFile.mains(root)
                   mains.is_a?(EntryFile::Missing) ? Array(String).new : mains
                 in .loose? then @loose
                 end
        remaining(target, listed)
      end

      private def failure_line(trace : String, reason : String) : String
        errors = trace.lines.select(&.starts_with?("Error: "))
        errors.last?.try(&.lchop("Error: ").strip) || reason
      end

      private def culprit(
        entry : String,
        trace : String,
        files : Array(String),
        root : String,
      ) : String?
        return if files.size < 2

        match = trace.match(/while requiring "([^"]+)"/)
        if match
          required = File.expand_path(match[1], File.dirname(entry))
          found = files.find { |file| file.rchop(".cr") == required }
          return found if found
        end

        files.find { |file| trace.includes?(file) || trace.includes?(file.sub(root + "/", "")) }
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
          [entry, root] + @defines.map { |flag| "-D#{flag}" },
          env: {"CRYSTAL_PATH" => crystal_path},
          chdir: root,
          output: output,
          error: errors,
        )
        unless status.success?
          reason = "#{SemanticHelper::NAME} exited #{status.exit_code}: #{errors.to_s.lines.first?}"
          return Index::MacrosFailed.new(target, reason, errors.to_s)
        end

        parsed = Index::MacroOutput.from_json(output.to_s)
        if (error = parsed.error)
          return Index::MacrosFailed.new(target, error, parsed.trace || error)
        end

        source = parsed.source
        unless source
          return Index::MacrosFailed.new(target, "the helper returned no source", "")
        end

        Index::MacrosExpanded.new(
          target, source, parsed.sites, parsed.files, Time.instant - started, excluded(target).dup
        )
      rescue error : JSON::ParseException
        Index::MacrosFailed.new(target, "the helper's output is not JSON: #{error.message}", "")
      rescue error : IO::Error | File::Error
        Index::MacrosFailed.new(target, error.message || error.class.name, "")
      end
    end
  end
end
