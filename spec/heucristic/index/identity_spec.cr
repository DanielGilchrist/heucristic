require "../../spec_helper"

describe Heucristic::Index::Identity do
  it "names its last segment" do
    public_type("Foo::Bar::Baz").last.should eq("Baz")
    public_type("Foo").last.should eq("Foo")
    private_type("Foo::Bar", "a.cr").last.should eq("Bar")
  end

  it "has the top level as the parent of an unqualified name" do
    public_type("Foo").parent.should be_a(Heucristic::Index::TopLevel)
    private_type("Foo", "a.cr").parent.should be_a(Heucristic::Index::TopLevel)
  end

  it "keeps its privacy in the parent" do
    public_type("Foo::Bar").parent.should eq(public_type("Foo"))
    private_type("Foo::Bar", "a.cr").parent.should eq(private_type("Foo", "a.cr"))
  end
end
