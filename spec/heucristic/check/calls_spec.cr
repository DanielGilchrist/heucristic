require "../../spec_helper"

private PRELUDE = <<-CR
  class Object
  end

  class Reference < Object
  end

  class String
    def size : Int32
    end
  end

  struct Int32
  end

  struct Bool
  end

  CR

private def codes(source : String) : Array(String)
  path = "/project/a.cr"
  full = PRELUDE + source
  text = Heucristic::Document::Text.new(full)
  tree = Heucristic::Syntax.parse(full, path)
  raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

  workspace = Heucristic::Index::Workspace.new
  workspace.update(Heucristic::Index::Collector.collect(path, text, tree, SPEC_CRYSTAL))
  types = Heucristic::Resolve::Types.new(workspace)
  methods = Heucristic::Resolve::Methods.new(workspace, types)
  receiver = Heucristic::Resolve::Receiver.new(
    workspace, Heucristic::Index::Shims.new, types, methods
  )
  settled = Heucristic::Check::Settled.new(
    workspace, types, methods.descendants, true, Set(String).new, Set{path}, "/project",
    Array(String).new
  )
  calls = Heucristic::Check::Calls.new(
    Heucristic::Check::Environment.new(workspace, types, methods, receiver, settled, "/project")
  )
  sites = Heucristic::Index::Sites.of(path, text, tree, SPEC_CRYSTAL)
  calls.run(sites).findings.map(&.rule.to_s.underscore)
end

private def codes_across(files : Hash(String, String), path : String) : Array(String)
  workspace = Heucristic::Index::Workspace.new
  parsed = Hash(String, {Heucristic::Document::Text, Crystal::ASTNode}).new
  files.each do |name, source|
    full = PRELUDE + source
    text = Heucristic::Document::Text.new(full)
    tree = Heucristic::Syntax.parse(full, name)
    raise "unexpected syntax error" unless tree.is_a?(Crystal::ASTNode)

    parsed[name] = {text, tree}
    workspace.update(Heucristic::Index::Collector.collect(name, text, tree, SPEC_CRYSTAL))
  end
  types = Heucristic::Resolve::Types.new(workspace)
  methods = Heucristic::Resolve::Methods.new(workspace, types)
  receiver = Heucristic::Resolve::Receiver.new(
    workspace, Heucristic::Index::Shims.new, types, methods
  )
  settled = Heucristic::Check::Settled.new(
    workspace, types, methods.descendants, true, Set(String).new, files.keys.to_set, "/project",
    Array(String).new
  )
  calls = Heucristic::Check::Calls.new(
    Heucristic::Check::Environment.new(workspace, types, methods, receiver, settled, "/project")
  )
  text, tree = parsed[path]
  sites = Heucristic::Index::Sites.of(path, text, tree, SPEC_CRYSTAL)
  calls.run(sites).findings.map(&.rule.to_s.underscore)
end

describe Heucristic::Check::Calls, "file-private types" do
  files = {
    "/project/a.cr" => <<-CR,
      private class Foo
        def only_a : Int32
          1
        end
      end

      def in_a
        Foo.new.only_a
        Foo.new.only_b
      end
      CR
    "/project/b.cr" => <<-CR,
      class Foo
        def only_b : Int32
          1
        end
      end

      def in_b
        Foo.new.only_b
        Foo.new.only_a
      end
      CR
  }

  it "flags a method only another file's same-named type defines" do
    codes_across(files, "/project/a.cr").should eq(["undefined_method"])
  end

  it "does not let a public type see the methods of a private type of the same name" do
    codes_across(files, "/project/b.cr").should eq(["undefined_method"])
  end
end

describe Heucristic::Check::Calls, "macro precedence" do
  it "lets a macro that accepts the call beat a def of the same class" do
    source = <<-CR
      class Keyed
        macro key(name)
        end

        def self.key(name : String) : String
          name
        end

        key(1)
      end
      CR
    codes(source).should be_empty
  end

  it "lets a macro that accepts the call beat a def of another arity in a superclass" do
    source = <<-CR
      class Base
        macro key(name)
        end

        def self.key : String
          ""
        end
      end

      class Sub < Base
        key :user
      end
      CR
    codes(source).should be_empty
  end

  it "lets a top-level macro that accepts the call beat a top-level def" do
    source = <<-CR
      macro key(name)
      end

      def key(name : String) : String
        name
      end

      key(1)
      CR
    codes(source).should be_empty
  end

  it "lets the def win when the macro's arity does not fit" do
    source = <<-CR
      class Keyed
        macro key(first, second)
        end

        def self.key(name : String) : String
          name
        end

        key(1)
      end
      CR
    codes(source).should eq(["type_mismatch"])
  end

  it "lets the def win when the macro rejects a named argument the def accepts" do
    source = <<-CR
      class Keyed
        macro key(name)
        end

        def self.key(name : Int32, flag : Bool = false) : String
          ""
        end

        def self.go : Int32
          key(1, flag: true).size
        end
      end
      CR
    codes(source).should be_empty
  end

  it "lets a def in a subclass shadow a macro in its superclass" do
    source = <<-CR
      class Base
        macro key(name)
        end
      end

      class Sub < Base
        def self.key(name : Int32, flag : Bool = false) : String
          ""
        end

        def self.go : Int32
          key(1, flag: true).size
        end
      end
      CR
    codes(source).should be_empty
  end

  it "checks a call against the subclass's def, not the superclass macro it shadows" do
    source = <<-CR
      class Base
        macro key(name)
        end
      end

      class Sub < Base
        def self.key(name : String) : String
          name
        end

        key(1)
      end
      CR
    codes(source).should eq(["type_mismatch"])
  end
end
