require "../../../src/heucristic/document/span"
require "../../../src/heucristic/index/macro_target"
require "../../../src/heucristic/index/entry"
require "../../../src/heucristic/syntax/target"
require "./accessors"
require "./group"
require "./judgement"
require "./observation"
require "./place"

module Score
  module Features
    class Judge
      DECLARING     = /\b(?:class|struct|module|enum|lib|annotation|alias|record)\s+(?:\w+::)*\z/
      CONSTANT_TAIL = /\A\s*(?::[^=]*)?=/

      record Slice, before : String, text : String, after : String

      def initialize(@definitions : Set(Place)) : Nil
        @lines = Hash(String, Array(String)?).new
        @accessors = Accessors.new
      end

      def judge(observation : Observation) : Judgement
        target = observation.target
        answer = observation.answer
        return Skipped.new("no target recorded") unless target && answer
        unless fits?(observation.site.kind.group, target)
          return Failed.new("the cursor landed on #{target.class.name.split("::").last}")
        end

        case target
        in Heucristic::Syntax::OnPath
          path(target.node.names[target.segment], answer)
        in Heucristic::Syntax::OnInstanceVar
          instance_var(target.name, answer)
        in Heucristic::Syntax::OnVar
          local(target, answer, observation)
        in Heucristic::Syntax::OnDef
          def_name(target, answer, observation)
        in Heucristic::Syntax::OnCall, Heucristic::Syntax::OnName, Heucristic::Syntax::OnRequire
          Skipped.new("not a declaration kind")
        end
      end

      private def path(name : String, answer : Heucristic::Server::Answer) : Judgement
        entries = answer.entries.reject { |entry| generated?(entry) }
        return Skipped.new("generated declaration") if entries.empty?

        entries.each do |entry|
          failure = declaration_failure(entry, name)
          return Failed.new(failure) if failure
        end
        Passed.new
      end

      private def instance_var(name : String, answer : Heucristic::Server::Answer) : Judgement
        entries = answer.entries.reject { |entry| generated?(entry) }
        return Skipped.new("no declaration, or generated") if entries.empty?

        entries.each do |entry|
          slice = slice_at(entry.path, entry.name_span)
          return Failed.new("no source at #{entry.path}") unless slice
          next if variable_declared?(slice, name, entry)

          return Failed.new("declaration text `#{slice.text}` is not `#{name}`")
        end
        Passed.new
      end

      private def local(
        target : Heucristic::Syntax::OnVar,
        answer : Heucristic::Server::Answer,
        observation : Observation,
      ) : Judgement
        return Skipped.new("no declaration span") if answer.spans.empty?

        answer.spans.each do |span|
          failure = local_failure(target, span, observation)
          return Failed.new(failure) if failure
        end
        Passed.new
      end

      private def def_name(
        target : Heucristic::Syntax::OnDef,
        answer : Heucristic::Server::Answer,
        observation : Observation,
      ) : Judgement
        return Skipped.new("no def entries") if answer.entries.empty?
        return Skipped.new("generated def") if answer.entries.all? { |e| generated?(e) }

        location = target.node.name_location
        return Skipped.new("def without a name location") unless location

        own = answer.entries.any? do |entry|
          entry.path == observation.path &&
            entry.name_span.start_line.to_i == location.line_number - 1 &&
            entry.name_span.start_character.to_i == location.column_number - 1
        end
        own ? Passed.new : Failed.new("no entry sits on the def's own name")
      end

      private def fits?(group : Group?, target : Heucristic::Syntax::Target) : Bool
        case group
        in Group::Call             then target.is_a?(Heucristic::Syntax::OnCall)
        in Group::Path             then target.is_a?(Heucristic::Syntax::OnPath)
        in Group::InstanceVariable then target.is_a?(Heucristic::Syntax::OnInstanceVar)
        in Group::Local            then target.is_a?(Heucristic::Syntax::OnVar)
        in Group::DefName          then target.is_a?(Heucristic::Syntax::OnDef)
        in Nil                     then true
        end
      end

      private def variable_declared?(
        slice : Slice,
        name : String,
        entry : Heucristic::Index::Entry,
      ) : Bool
        return true if slice.text == name
        return false unless slice.text == name.lstrip('@')

        slice.before.ends_with?('@') || @accessors.declares?(entry.path, entry.name_span)
      end

      private def declaration_failure(entry : Heucristic::Index::Entry, name : String) : String?
        slice = slice_at(entry.path, entry.name_span)
        return "no source at #{entry.path}:#{entry.name_span.start_line + 1}" unless slice
        unless slice.text.split("::").last == name
          return "declaration text `#{slice.text}` is not `#{name}`"
        end

        case entry
        in Heucristic::Index::Namespace, Heucristic::Index::Alias
          return if DECLARING.matches?(slice.before)

          "`#{slice.before.strip}` before the name is not a type declaration"
        in Heucristic::Index::Constant
          return if CONSTANT_TAIL.matches?(slice.after) || slice.after.blank?

          "`#{name}` is not assigned on its declaring line"
        in Heucristic::Index::Def, Heucristic::Index::InstanceVar
          "an unexpected #{entry.class.name.split("::").last} answered a constant path"
        end
      end

      private def local_failure(
        target : Heucristic::Syntax::OnVar,
        span : Heucristic::Document::Span,
        observation : Observation,
      ) : String?
        line = span.start_line.to_i + 1
        column = span.start_character.to_i + 1
        slice = slice_at(observation.path, span)
        return "declaration span is outside the file" unless slice
        unless slice.text == target.name
          return "declaration text `#{slice.text}` is not `#{target.name}`"
        end
        unless @definitions.includes?(Place.new(observation.path, line, column))
          return "no declaration of `#{target.name}` at #{line}:#{column}"
        end
        return "declared after the use" if line > observation.site.line

        scope = target.context.def_node
        first = scope.try(&.location).try(&.line_number)
        last = scope.try(&.end_location).try(&.line_number)
        return unless first && last
        return if line >= first && line <= last

        "declaration at line #{line} lies outside the enclosing def (#{first}-#{last})"
      end

      private def generated?(entry : Heucristic::Index::Entry) : Bool
        Heucristic::Index::MacroTarget.generated?(entry.path)
      end

      private def slice_at(path : String, span : Heucristic::Document::Span) : Slice?
        lines = (@lines[path] ||= read(path))
        return unless lines && span.start_line == span.end_line

        line = lines[span.start_line]?
        return unless line

        from = span.start_character.to_i
        to = span.end_character.to_i
        return if to > line.size

        Slice.new(line[0, from], line[from, to - from], line[to..])
      end

      private def read(path : String) : Array(String)?
        File.read_lines(path) if File.file?(path)
      end
    end
  end
end
