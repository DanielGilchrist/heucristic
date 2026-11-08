require "../../spec_helper"

private NOW = Time.utc(2026, 1, 10)

private def aged(name : String, age : Time::Span) : Heucristic::Index::StaleShims::Entry
  Heucristic::Index::StaleShims::Entry.new(name, NOW - age)
end

describe Heucristic::Index::StaleShims do
  it "keeps the current digest and anything touched within the window" do
    entries = [
      aged("a", 30.days),
      aged("b", 1.day),
      aged("c", 8.days),
      aged("d", 6.days),
    ]
    Heucristic::Index::StaleShims.expired(entries, "a", NOW).should eq(["c"])
  end

  it "honours an injected window" do
    entries = [aged("a", 2.hours), aged("b", 30.minutes)]
    Heucristic::Index::StaleShims.expired(entries, "z", NOW, 1.hour).should eq(["a"])
  end
end
