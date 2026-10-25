require "../../spec_helper"

private def misplaced(source : String) : Array(String)
  tree = Heucristic::Syntax.parse(source, "a.cr")
  raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

  sites = Heucristic::Index::Sites.of("a.cr", Heucristic::Document::Text.new(source), tree)
  findings = Array(Heucristic::Check::Finding).new
  Heucristic::Check::Controls.new.run(sites, findings)
  findings.map { |finding| "#{finding.span.start_line + 1}: #{finding.message}" }
end

describe Heucristic::Check::Controls do
  it "allows a return inside an accessor's lazy block, which the macro inlines into its method" do
    source = <<-CR
      class Report
        getter status : String? do
          return if ready?
          "x"
        end

        class_getter shared : String? do
          return
        end
      end
      return
      CR
    misplaced(source).should eq(["11: can't return from top level"])
  end
end
