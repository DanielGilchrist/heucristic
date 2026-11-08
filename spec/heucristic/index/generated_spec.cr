require "../../spec_helper"

private USER_SOURCE = "class User\n  def email : String\n  end\nend\n"

private def file(path : String, source : String) : Heucristic::Index::File
  tree = Heucristic::Syntax.parse(source, path)
  raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

  Heucristic::Index::Collector.collect(
    path, Heucristic::Document::Text.new(source), tree, SPEC_CRYSTAL
  )
end

private def merged_names(twin_path : String, loaded : Set(String)) : Array(String)
  workspace = Heucristic::Index::Workspace.new
  workspace.update(file(twin_path, USER_SOURCE))
  generated = file("<macros>", "class ::User\n  def email : String\n  end\nend\n")
  files = Heucristic::Index::LoadedFiles.new(loaded, Array(String).new)

  sites = Array(Heucristic::Index::MacroSite).new
  shims = Heucristic::Index::Shims.new
  none = Array(Heucristic::Index::Reopening).new
  merged = Heucristic::Index::Generated.merge(generated, sites, none, workspace, shims, files)
  merged.defs.map(&.name)
end

private def reopened_mixins(reopenings : Array({String, String?})) : Array(Bool)
  generated = file("<macros>", "struct ::Foo\n  include ::M\nend\n")
  files = Heucristic::Index::LoadedFiles.new(Set(String).new, Array(String).new)
  entries = reopenings.map { |name, path| Heucristic::Index::Reopening.new(name, path) }
  merged = Heucristic::Index::Generated.merge(
    generated, Array(Heucristic::Index::MacroSite).new, entries, Heucristic::Index::Workspace.new,
    Heucristic::Index::Shims.new, files
  )
  merged.mixins.map { |mixin| private_owner?(mixin.owner) }
end

private def private_owner?(owner : Heucristic::Index::Owner) : Bool
  case owner
  in Heucristic::Index::Identity then owner.private?
  in Heucristic::Index::TopLevel then false
  end
end

describe Heucristic::Index::Generated, "reopenings of file-private types" do
  it "attaches the include of a private type's reopening to the private identity" do
    reopened_mixins([{"Foo", "a.cr"}]).should eq([true])
  end

  it "attaches it to the public type when the reopening is public" do
    reopened_mixins([{"Foo", nil}]).should eq([false])
  end

  it "drops the include when the name is reopened both privately and publicly" do
    reopened_mixins([{"Foo", "a.cr"}, {"Foo", nil}]).should be_empty
  end

  it "drops the include when the name is private to several files" do
    reopened_mixins([{"Foo", "a.cr"}, {"Foo", "b.cr"}]).should be_empty
  end
end

describe Heucristic::Index::Generated do
  it "keeps a generated def whose twin sits in a file the compiler never loaded" do
    merged_names("lib/cache/spec/user_spec.cr", Set(String).new).should eq(["email"])
  end

  it "drops a generated def already declared in a file the compiler loaded" do
    merged_names("src/user.cr", Set{"src/user.cr"}).should be_empty
  end

  it "types the == a def_equals expansion generates as Bool, other generated defs untouched" do
    generated = file(
      "<macros>", "class ::Node\n  def ==(other : self)\n  end\n\n  def other(x)\n  end\nend\n"
    )
    site = Heucristic::Index::MacroSite.new(
      2, "Node", "==", false, "def_equals_and_hash", nil, nil, nil, nil, nil
    )
    files = Heucristic::Index::LoadedFiles.new(Set(String).new, Array(String).new)
    workspace = Heucristic::Index::Workspace.new
    shims = Heucristic::Index::Shims.new
    merged = Heucristic::Index::Generated.merge(
      generated, [site], Array(Heucristic::Index::Reopening).new, workspace, shims, files
    )
    returns = merged.defs.map(&.return_type.to_s)
    returns.should eq(["::Bool", "Heucristic::Index::Unrestricted()"])
  end
end
