require "../index/workspace"
require "../resolve/methods"
require "./environment"
require "./inspection"
require "./finding"
require "./settled"

module Heucristic
  module Check
    struct Abstracts
      include Inspection

      @workspace : Index::Workspace
      @methods : Resolve::Methods
      @settled : Settled

      def initialize(environment : Environment) : Nil
        @workspace = environment.workspace
        @methods = environment.methods
        @settled = environment.settled
      end

      def run(sites : Index::Sites, findings : Array(Finding)) : Nil
        path = sites.path
        file = @workspace.file(path)
        return unless file

        file.namespaces.each do |entry|
          next unless entry.is_a?(Index::ClassNamespace)
          next if entry.abstract_type
          next unless primary?(entry)
          next unless @settled.declared?(entry.identity)

          check(path, entry, findings)
        end
      end

      private def primary?(entry : Index::ClassNamespace) : Bool
        first = @workspace.namespaces(entry.identity).min_by do |other|
          {other.path, other.name_span.start_line}
        end
        first.path == entry.path && first.name_span == entry.name_span
      end

      private def check(
        path : String,
        entry : Index::ClassNamespace,
        findings : Array(Finding),
      ) : Nil
        levels = @methods.levels(entry.identity)
        levels.each do |level|
          @workspace.defs_of(level).each do |definition|
            next unless definition.abstract_def && @methods.own?(definition, path)
            next if implemented?(definition, levels)

            message = String.build do |io|
              io << "abstract `def " << definition.qualified << '('
              definition.parameters.join(io, ", ")
              io << ")` must be implemented by " << entry.name
            end
            findings << Finding.new(:abstract_not_implemented, message, entry.name_span)
          end
        end
      end

      private def implemented?(definition : Index::Def, levels : Array(Index::Identity)) : Bool
        @workspace.named(definition.name).any? do |candidate|
          levels.includes?(candidate.owner) && candidate.receiver == definition.receiver &&
            !candidate.abstract_def
        end
      end
    end
  end
end
