require "../../spec_helper"
require "../../../tools/score/features/inquiry"
require "../../../tools/score/features/table"

private SOURCE = <<-CRYSTAL
  class Greeter
    @name : String = "x"

    def greet(name : String) : String
      name
    end

    def mystery(thing)
      thing.upcase
    end

    def own : String
      @name
    end
  end

  Greeter.new.greet("a")
  CRYSTAL

private def observe(source : String) : Array(Score::Features::Observation)
  tree = Heucristic::Syntax.parse(source, "a.cr")
  raise "syntax error" unless tree.is_a?(Crystal::ASTNode)

  workspace = Heucristic::Index::Workspace.new
  workspace.update(
    Heucristic::Index::Collector.collect(
      "a.cr", Heucristic::Document::Text.new(source), tree, SPEC_CRYSTAL
    )
  )
  types = Heucristic::Resolve::Types.new(workspace)
  methods = Heucristic::Resolve::Methods.new(workspace, types)
  receiver = Heucristic::Resolve::Receiver.new(
    workspace, Heucristic::Index::Shims.new, types, methods
  )
  Score::Features::Inquiry.over(
    workspace, types, methods, receiver,
    Hash(String, Heucristic::Index::MacroSite).new, "/"
  ).observe("a.cr", source)
end

private def reply_at(
  observations : Array(Score::Features::Observation),
  kind : Score::Features::Kind,
  line : Int32,
  name : String,
) : Score::Features::Reply
  found = observations.find do |observation|
    site = observation.site
    site.kind == kind && site.line == line && site.name == name
  end
  raise "no #{kind} #{name} on line #{line}" unless found

  found.reply
end

describe Score::Features::Inquiry do
  observations = observe(SOURCE)

  it "answers a call with a declaration and locates it" do
    reply_at(observations, :call_with_receiver, 17, "greet").should eq(
      Score::Features::Answered.new(true)
    )
  end

  it "reports whether an answered position can be followed to a declaration" do
    observations.any?(&.answered_and_located?).should be_true
    observations.all?(&.answered_and_located?).should be_false
  end

  it "answers a constant path with the type it names" do
    reply_at(observations, :constant_path, 17, "Greeter").should eq(
      Score::Features::Answered.new(true)
    )
  end

  it "answers a parameter use with its declaration" do
    reply_at(observations, :local_use, 5, "name").should eq Score::Features::Answered.new(true)
  end

  it "answers an instance variable with its declaration" do
    reply_at(observations, :instance_var, 13, "@name").should eq(
      Score::Features::Answered.new(true)
    )
  end

  it "answers a def name" do
    reply_at(observations, :def_name, 4, "greet").should eq Score::Features::Answered.new(true)
  end

  it "groups an untyped receiver under its reason with the detail kept" do
    reply = reply_at(observations, :call_with_receiver, 9, "upcase")
    unless reply.is_a?(Score::Features::Unanswered)
      raise "expected an unanswered reply, got #{reply}"
    end

    reply.reason.should eq "receiver of _: unknown (no annotation)"
    reply.detail.should contain("thing")
  end

  it "tallies every observation under its kind" do
    table = Score::Features::Table.new
    observations.each { |observation| table.add(observation) }
    table.total.should eq observations.size
    bugs = observations.count do |observation|
      observation.reply.is_a?(Score::Features::Empty) ||
        observation.reply.is_a?(Score::Features::Crashed)
    end
    table.defects.should eq bugs
    table.rows[Score::Features::Kind::CallWithReceiver].unanswered.should eq 1
  end
end
