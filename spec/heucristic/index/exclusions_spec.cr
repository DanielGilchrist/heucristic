require "../../spec_helper"

describe Heucristic::Index::Exclusions do
  it "has no note when nothing is excluded" do
    Heucristic::Index::Exclusions.none.note("/root").should be_nil
  end

  it "keeps the earlier value intact when adding" do
    none = Heucristic::Index::Exclusions.none
    one = none.plus("/root/a.cr", "boom")

    none.reject_from(["/root/a.cr"]).should eq ["/root/a.cr"]
    one.reject_from(["/root/a.cr"]).should be_empty
  end

  it "rejects excluded files in order" do
    exclusions = Heucristic::Index::Exclusions.none.plus("/root/b.cr", "boom")

    exclusions.reject_from(["/root/a.cr", "/root/b.cr", "/root/c.cr"])
      .should eq ["/root/a.cr", "/root/c.cr"]
  end

  it "notes each path relative to the root with the first line of its reason" do
    exclusions = Heucristic::Index::Exclusions.none
      .plus("/root/src/a.cr", "undefined constant\nmore detail")
      .plus("/root/src/b.cr", "wrong arity")

    exclusions.note("/root").should eq(
      "left out of the expansion because it failed: " \
      "src/a.cr (undefined constant), src/b.cr (wrong arity)"
    )
  end
end
