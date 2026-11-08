require "../index/sites"
require "../index/workspace"
require "../resolve/methods"
require "../resolve/types"
require "../resolve/receiver"
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
      def initialize(
        workspace : Index::Workspace,
        types : Resolve::Types,
        methods : Resolve::Methods,
        receiver : Resolve::Receiver,
        settled : Settled,
        root : String,
      ) : Nil
        @calls = Calls.new(workspace, types, methods, receiver, settled)
        @cases = Cases.new(workspace, types, receiver, settled)
        @abstracts = Abstracts.new(workspace, methods, settled)
        @generics = Generics.new(workspace, types, settled, root)
        @controls = Controls.new(workspace)
        @paths = Paths.new(workspace, types, settled)
        @returns = Returns.new(types, methods, receiver, settled)
        @instance_vars = InstanceVars.new(workspace, types, methods, receiver, settled)
      end

      def run(sites : Index::Sites) : Outcome
        outcome = @calls.run(sites)
        findings = outcome.findings
        @cases.run(sites, findings)
        @abstracts.run(sites.path, findings)
        @generics.run(sites, findings)
        @controls.run(sites, findings)
        @paths.run(sites, findings)
        @returns.run(sites, findings)
        @instance_vars.run(sites, findings)
        findings.sort_by! { |finding| {finding.span.start_line, finding.span.start_character} }
        outcome
      end

      def findings(sites : Index::Sites) : Array(Finding)
        run(sites).findings
      end
    end
  end
end
