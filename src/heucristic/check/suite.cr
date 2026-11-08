require "../index/sites"
require "../index/workspace"
require "../resolve/methods"
require "../resolve/types"
require "../resolve/receiver"
require "./environment"
require "./inspection"
require "./abstracts"
require "./calls"
require "./cases"
require "./controls"
require "./finding"
require "./generics"
require "./instance_vars"
require "./outcome"
require "./paths"
require "./returns"
require "./settled"

module Heucristic
  module Check
    class Suite
      def initialize(environment : Environment) : Nil
        @calls = Calls.new(environment)
        @inspections = [
          Cases.new(environment),
          Abstracts.new(environment),
          Generics.new(environment),
          Controls.new(environment),
          Paths.new(environment),
          Returns.new(environment),
          InstanceVars.new(environment),
        ] of Inspection
      end

      def run(sites : Index::Sites) : Outcome
        outcome = @calls.run(sites)
        findings = outcome.findings
        @inspections.each(&.run(sites, findings))
        findings.sort_by! { |finding| {finding.span.start_line, finding.span.start_character} }
        outcome
      end

      def findings(sites : Index::Sites) : Array(Finding)
        run(sites).findings
      end
    end
  end
end
