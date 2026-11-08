require "../../spec_helper"

private URI_A = "file:///tmp/heucristic-spec/a.cr"
private URI_B = "file:///tmp/heucristic-spec/b.cr"

private def completion_labels(response : Heucristic::Protocol::Response) : Array(String)?
  response.result.try(&.["items"].as_a.map(&.["label"].as_s))
end

private def hover_text(response : Heucristic::Protocol::Response) : String?
  response.result.try(&.["contents"]?).try(&.["value"]?).try(&.as_s?)
end

private alias Notice = Heucristic::Server::Notice
private alias Stage = Heucristic::Server::Stage

describe Heucristic::Server::Loop do
  it "initializes and reports hover and definition capabilities" do
    client = LspClient.in_process
    response = client.initialize!(Dir.current)
    capabilities = response.result.try(&.["capabilities"]?)
    capabilities.try(&.["hoverProvider"]?).try(&.as_bool?).should be_true
    capabilities.try(&.["definitionProvider"]?).try(&.as_bool?).should be_true
    client.await_notification(Notice::Indexed, 30.seconds)
    client.shutdown
  end

  it "publishes a syntax error and clears it after a fixing edit" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification(Notice::Indexed)

    client.open(URI_A, "def foo(\nend\n")
    published = client.await_diagnostics
    published.params.try(&.["diagnostics"]?).try(&.as_a?).try(&.size).should eq(1)

    range = {"start" => {"line" => 0, "character" => 7}, "end" => {"line" => 0, "character" => 8}}
    client.change(URI_A, 2, [{"range" => range, "text" => ""}])
    cleared = client.await_diagnostics
    cleared.params.try(&.["diagnostics"]?).try(&.as_a?).try(&.size).should eq(0)
    cleared.params.try(&.["version"]?).try(&.as_i?).should eq(2)
    client.shutdown
  end

  it "answers hover and definition for a receiverless call from the open document" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification(Notice::Indexed)

    client.open(URI_A, "def greet(name : String) : String\n  name\nend\n\ngreet(\"x\")\n")
    client.await_diagnostics

    hover_text(client.hover(URI_A, 4, 1)).to_s.should contain("def greet(name : String) : String")
    definition = client.definition(URI_A, 4, 1).result.try(&.as_a?)
    definition.try(&.size).should eq(1)
    definition.try(&.[0]["range"]["start"]["line"].as_i).should eq(0)
    definition.try(&.[0]["range"]["start"]["character"].as_i).should eq(4)
    client.shutdown
  end

  it "jumps from super to the def it reaches and from a call to every override" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification(Notice::Indexed)

    client.open(URI_A, <<-CR)
      class Node
        def location : Nil
        end
      end

      class Leaf < Node
        def location : Nil
          super
        end
      end

      def find(node : Node) : Nil
        node.location
      end
      CR
    client.await_diagnostics

    definition = client.definition(URI_A, 7, 4).result.try(&.as_a?)
    definition.try(&.map(&.["range"]["start"]["line"].as_i)).should eq([1])
    definition = client.definition(URI_A, 12, 8).result.try(&.as_a?)
    definition.try(&.map(&.["range"]["start"]["line"].as_i)).should eq([1, 6])
    client.shutdown
  end

  it "lists what each call passes an untyped parameter and suggests the restriction" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification(Notice::Indexed)

    client.open(URI_A, <<-CR)
      class Greeter
        def greet(name)
          name
        end
      end

      def run(greeter : Greeter) : Nil
        greeter.greet("a")
        greeter.greet(1)
      end
      CR
    client.await_diagnostics

    text = hover_text(client.hover(URI_A, 2, 4)).to_s
    text.should contain("parameter name has no type restriction")
    text.should contain("2 indexed calls to `Greeter#greet` pass `name`:")
    text.should contain("a.cr:8` `String`")
    text.should contain("a.cr:9` `Int32`")
    text.should contain("Every call is typed: `name : String | Int32` states what they pass.")
    client.shutdown
  end

  it "suggests no restriction while a call with an untyped receiver may reach the def" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification(Notice::Indexed)

    client.open(URI_A, <<-CR)
      class Greeter
        def greet(name)
          name
        end
      end

      def run(greeter : Greeter, other) : Nil
        greeter.greet("a")
        other.greet(1)
      end
      CR
    client.await_diagnostics

    text = hover_text(client.hover(URI_A, 2, 4)).to_s
    text.should contain("1 indexed call to `Greeter#greet` passes `name`:")
    text.should contain("1 other call to `greet` cannot be attributed")
    text.should contain("No restriction is suggested while some calls are not attributed.")
    client.shutdown
  end

  it "says when a call takes the default" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification(Notice::Indexed)

    client.open(URI_A, <<-CR)
      class Greeter
        def greet(name = "you")
          name
        end
      end

      def run(greeter : Greeter) : Nil
        greeter.greet
      end
      CR
    client.await_diagnostics

    text = hover_text(client.hover(URI_A, 2, 4)).to_s
    text.should contain("a.cr:8` `String` from the default")
    text.should contain("Every call is typed: `name : String` states what they pass.")
    client.shutdown
  end

  it "suggests no restriction while a call passes a value it cannot type" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification(Notice::Indexed)

    client.open(URI_A, <<-CR)
      class Greeter
        def greet(name)
          name
        end
      end

      def run(greeter : Greeter, other) : Nil
        greeter.greet("a")
        greeter.greet(other)
      end
      CR
    client.await_diagnostics

    text = hover_text(client.hover(URI_A, 2, 4)).to_s
    text.should contain("a.cr:9` unknown (no annotation: parameter other has no type restriction)")
    text.should contain("1 of 2 are not typed, so no restriction is suggested.")
    client.shutdown
  end

  it "suggests no restriction while a passed type holds an unknown argument" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification(Notice::Indexed)

    client.open(URI_A, <<-CR)
      class Greeter
        def greet(names)
          names
        end
      end

      def run(greeter : Greeter) : Nil
        greeter.greet([] of Missing)
      end
      CR
    client.await_diagnostics

    text = hover_text(client.hover(URI_A, 2, 4)).to_s
    text.should_not contain("Every call is typed")
    text.should contain("1 of 1 are not typed, so no restriction is suggested.")
    client.shutdown
  end

  it "does not attribute a parameter a splat argument fills to its default" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification(Notice::Indexed)

    client.open(URI_A, <<-CR)
      class Greeter
        def greet(first, last = 1)
          last
        end
      end

      def run(greeter : Greeter, pair : Tuple(String, String)) : Nil
        greeter.greet(*pair)
      end
      CR
    client.await_diagnostics

    text = hover_text(client.hover(URI_A, 2, 4)).to_s
    text.should_not contain("from the default")
    text.should_not contain("Every call is typed")
    client.shutdown
  end

  it "explains a call it cannot resolve and gives no definition" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification(Notice::Indexed)

    client.open(URI_A, "x = 1\nx.abs\n")
    client.await_diagnostics

    hover_text(client.hover(URI_A, 1, 2)).to_s.should eq("no `abs` indexed on Int32")
    client.definition(URI_A, 1, 2).result.try(&.raw).should be_nil
    client.shutdown
  end

  it "rejects an unknown method with method not found" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    response = client.request_raw("textDocument/unknownThing", {"x" => 1})
    response.error.try(&.["code"]?).try(&.as_i?).should eq(-32601)
    client.shutdown
  end

  it "answers hover on the name of a def whose receiver is a constant" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification(Notice::Indexed)

    client.open(URI_A, <<-CR)
      class Foo
      end

      def Foo.bar : Int32
        1
      end

      module A
        module B
          def A::C.zap : Int32
            2
          end
        end
      end
      CR
    client.await_diagnostics

    hover_text(client.hover(URI_A, 3, 9)).to_s.should contain("def self.bar : Int32")
    hover_text(client.hover(URI_A, 9, 15)).to_s.should contain("def self.zap : Int32")
    client.shutdown
  end

  it "initializes when initializationOptions is not an object" do
    client = LspClient.in_process
    response = client.request_raw("initialize", {
      "processId"             => nil,
      "rootUri"               => "file:///tmp/heucristic-spec-empty",
      "capabilities"          => Hash(String, String).new,
      "initializationOptions" => [false],
    })
    response.result.try(&.["capabilities"]?).try(&.["hoverProvider"]?).should_not be_nil
    client.shutdown
  end

  it "resolves a constant through the enclosing namespaces and lists every reopening" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification(Notice::Indexed)

    source = <<-CR
      class Thing
      end

      module Outer
        class Thing
        end

        class Thing
          def make : Thing
            Thing.new
          end
        end
      end
      CR
    client.open(URI_A, source)
    client.await_diagnostics

    definition = client.definition(URI_A, 9, 6).result.try(&.as_a?)
    definition.try(&.map(&.["range"]["start"]["line"].as_i)).should eq([4, 7])
    hover = hover_text(client.hover(URI_A, 9, 6)).to_s
    hover.should contain("class Outer::Thing")
    hover.should contain("# reopened in 2 places")
    hover.scan("class Outer::Thing").size.should eq(1)
    client.shutdown
  end

  it "jumps to an alias even when its target does not resolve" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification(Notice::Indexed)

    client.open(URI_A, "alias Broken = Missing | Nil\n\ndef f(x : Broken)\nend\n")
    client.await_diagnostics

    definition = client.definition(URI_A, 2, 11).result.try(&.as_a?)
    definition.try(&.map(&.["range"]["start"]["line"].as_i)).should eq([0])
    hover_text(client.hover(URI_A, 2, 11)).to_s.should contain("alias Broken = Missing | Nil")
    client.shutdown
  end

  it "resolves an implicit self call to the enclosing type instead of the whole workspace" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification(Notice::Indexed)

    source = <<-CR
      class Other
        def initialize(x : Int32) : Nil
        end
      end

      class Cursor
        def initialize(point : Int32) : Nil
        end

        def self.find(point : Int32) : Cursor
          new(point)
        end
      end
      CR
    client.open(URI_A, source)
    client.await_diagnostics

    definition = client.definition(URI_A, 10, 5).result.try(&.as_a?)
    definition.try(&.map(&.["range"]["start"]["line"].as_i)).should eq([6])
    client.shutdown
  end

  it "shows a parameter's declared type on hover and jumps to the parameter" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification(Notice::Indexed)

    source = "class Box\n  def fill(item : String, other) : Nil\n    item\n    other\n  end\nend\n"
    client.open(URI_A, source)
    client.await_diagnostics

    hover_text(client.hover(URI_A, 2, 5)).to_s.should eq("```crystal\nString\n```")
    hover_text(client.hover(URI_A, 3, 5)).to_s.should contain("no type restriction")
    definition = client.definition(URI_A, 2, 5).result.try(&.as_a?)
    definition.try(&.map(&.["range"]["start"]["character"].as_i)).should eq([11])
    client.shutdown
  end

  it "answers hover and definition for a method only an abstract base's subclasses define" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification(Notice::Indexed)

    source = <<-CR
      abstract class Shape
      end

      class Circle < Shape
        def area : Float64
        end
      end

      class Square < Shape
        def area : Int32
        end
      end

      def measure(shape : Shape) : Nil
        shape.area
      end
      CR
    client.open(URI_A, source)
    client.await_diagnostics

    hover = hover_text(client.hover(URI_A, 14, 9)).to_s
    hover.should contain("def area : Float64")
    hover.should contain("def area : Int32")
    definition = client.definition(URI_A, 14, 9).result.try(&.as_a?)
    definition.try(&.map(&.["range"]["start"]["line"].as_i).sort!).should eq([4, 9])
    client.shutdown
  end

  it "answers hover for a select condition through the action the compiler calls" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification(Notice::Indexed)

    source = <<-CR
      def timeout_select_action(timeout : Time::Span) : Channel::TimeoutAction
      end

      class Waiter
        def wait(duration : Time::Span, stop : Channel(Nil)) : Bool
          select
          when stop.receive
            false
          when timeout(duration)
            true
          end
        end
      end
      CR
    client.open(URI_A, source)
    client.await_diagnostics

    hover_text(client.hover(URI_A, 8, 10)).to_s.should contain(
      "def timeout_select_action(timeout : Time::Span)"
    )
    client.shutdown
  end

  it "answers hover for a call forwarded by forward_missing_to" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification(Notice::Indexed)

    source = <<-CR
      class Store
        def lookup(key : String) : Bool?
        end
      end

      class Cache
        @store = Store.new

        forward_missing_to @store
      end

      def allowed?(cache : Cache) : Nil
        cache.lookup("a")
      end
      CR
    client.open(URI_A, source)
    client.await_diagnostics

    hover = hover_text(client.hover(URI_A, 12, 9)).to_s
    hover.should contain("def lookup(key : String) : Bool | Nil")
    client.shutdown
  end

  it "explains why a call cannot be resolved instead of guessing" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification(Notice::Indexed)

    client.open(URI_A, "def go(x)\n  x.size\nend\n")
    client.await_diagnostics

    hover_text(client.hover(URI_A, 1, 5)).to_s.should contain("parameter x has no type restriction")
    client.definition(URI_A, 1, 5).result.try(&.raw).should be_nil
    client.shutdown
  end

  it "types an ivar assigned with Const.new and resolves a call on it" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification(Notice::Indexed)

    source = <<-CR
      class Workspace
        def update(name : String) : Nil
        end
      end

      class Session
        def initialize : Nil
          @workspace = Workspace.new
        end

        def go : Nil
          @workspace.update("x")
        end
      end
      CR
    client.open(URI_A, source)
    client.await_diagnostics

    hover_text(client.hover(URI_A, 11, 6)).to_s.should eq("```crystal\nWorkspace\n```")
    definition = client.definition(URI_A, 11, 16).result.try(&.as_a?)
    definition.try(&.map(&.["range"]["start"]["line"].as_i)).should eq([1])
    client.shutdown
  end

  it "reports indexing progress when the client supports it" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty", progress: true)

    create = select
    when request = client.requests.receive
      request
    when timeout(5.seconds)
      raise "no progress create request"
    end
    create.method.should eq("window/workDoneProgress/create")

    kinds = Array(String).new
    until kinds.last? == "end"
      value = client.await_notification(:progress).params.try(&.["value"]?)
      kinds << value.try(&.["kind"]?).try(&.as_s?).to_s
    end
    kinds.first.should eq("begin")
    kinds.last.should eq("end")
    client.shutdown
  end

  it "stays silent about progress when the client does not support it" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    indexed = client.await_notification(Notice::Indexed)
    (indexed.params.try(&.["files"]?).try(&.as_i?) || -1).should be < 10
    client.shutdown
  end

  it "indexes the stdlib on request and resolves a call on a string literal" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty", stdlib: true)
    indexed = client.await_notification(Notice::Indexed, 60.seconds)
    (indexed.params.try(&.["files"]?).try(&.as_i?) || 0).should be > 1000

    client.open(URI_A, "\"x\".size\n")
    client.await_diagnostics

    hover_text(client.hover(URI_A, 0, 5)).to_s.should contain("String#size")
    client.shutdown
  end

  it "resolves a constant through its namespace and shows its value" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification(Notice::Indexed)

    client.open(URI_A, "module Fibers\n  WORKERS = 4\nend\n\nx = Fibers::WORKERS\n")
    client.await_diagnostics

    hover_text(client.hover(URI_A, 4, 14)).to_s.should eq(
      "```crystal\nFibers::WORKERS = 4 # : Int32\n```"
    )
    definition = client.definition(URI_A, 4, 14).result.try(&.as_a?)
    definition.try(&.map(&.["range"]["start"]["line"].as_i)).should eq([1])
    client.shutdown
  end

  it "shows what a call returns after binding the receiver's type arguments" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification(Notice::Indexed)

    source = <<-CR
      class Channel(T)
        def receive : T
        end
      end

      class Loader
        def load(results : Channel(String?)) : Nil
          results.receive
        end
      end
      CR
    client.open(URI_A, source)
    client.await_diagnostics

    hover_text(client.hover(URI_A, 7, 13)).to_s.should contain("def receive : String | Nil")
    client.shutdown
  end

  it "resolves an enum member and the enum itself from one path" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification(Notice::Indexed)

    client.open(URI_A, "enum Kind\n  Splat\nend\n\nx = Kind::Splat\n")
    client.await_diagnostics

    hover_text(client.hover(URI_A, 4, 10)).to_s.should eq("```crystal\nKind::Splat\n```")
    hover_text(client.hover(URI_A, 4, 5)).to_s.should eq("```crystal\nenum Kind\n```")
    definition = client.definition(URI_A, 4, 10).result.try(&.as_a?)
    definition.try(&.map(&.["range"]["start"]["line"].as_i)).should eq([1])
    client.shutdown
  end

  it "always explains a hover it cannot answer" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification(Notice::Indexed)

    client.open(URI_A, "x = Missing::Thing\n\n")
    client.await_diagnostics

    hover_text(client.hover(URI_A, 0, 6)).to_s.should eq("unknown (unresolved name: Missing)")
    hover_text(client.hover(URI_A, 1, 0)).to_s.should contain("under the cursor")
    hover_text(client.hover(URI_A, 9, 0)).to_s.should eq("position is outside the document")
    client.definition(URI_A, 0, 6).result.try(&.raw).should be_nil
    client.shutdown
  end

  it "renders the whole signature with the receiver's bindings" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification(Notice::Indexed)

    source = <<-CR
      module Enumerable(T)
        def each(& : T ->) : Nil
        end
      end

      class Array(T)
        include Enumerable(T)
      end

      def go(names : Array(String)) : Nil
        names.each { |name| name }
      end
      CR
    client.open(URI_A, source)
    client.await_diagnostics

    hover_text(client.hover(URI_A, 10, 9)).to_s.should eq(
      "```crystal\n# Enumerable#each\ndef each(& : String ->) : Nil\n```"
    )
    client.shutdown
  end
end

describe Heucristic::Server::Loop, "variable definitions" do
  it "jumps from a variable to its first assignment and from an ivar to its assignment" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification(Notice::Indexed)

    source = <<-CR
      class Sync
        def initialize : Nil
          @started = Time.instant
        end

        def run(items : Array(String)) : Nil
          target = items.first
          items.each do |item|
            item.size
          end
          target.size
          @started.to_s
        end
      end
      CR
    client.open(URI_A, source)
    client.await_diagnostics

    definition = client.definition(URI_A, 10, 5).result.try(&.as_a?)
    definition.try(&.map(&.["range"]["start"]["line"].as_i)).should eq([6])
    definition = client.definition(URI_A, 8, 7).result.try(&.as_a?)
    definition.try(&.map(&.["range"]["start"]["line"].as_i)).should eq([7])
    definition = client.definition(URI_A, 11, 5).result.try(&.as_a?)
    definition.try(&.map(&.["range"]["start"]["line"].as_i)).should eq([2])
    client.shutdown
  end
end

describe Heucristic::Server::Loop, "macro expansion" do
  root = File.expand_path("../../fixtures/macros", __DIR__)
  fake = File.expand_path("../../support/fake_semantic", __DIR__)
  failing = File.expand_path("../../support/failing_semantic", __DIR__)

  it "adds generated defs with provenance and jumps to the expansion site" do
    client = LspClient.in_process
    client.initialize!(root, semantic: fake)
    client.await_notification(Notice::Indexed)
    status = client.await_stage(Notice::Macros, Stage::Done)
    status.params.try(&.["defs"].as_i).should eq(1)

    client.open(URI_A, "Command.parse(ARGV)\n")
    client.await_diagnostics
    text = hover_text(client.hover(URI_A, 0, 9)).to_s
    text.should contain("def self.parse(args : Array(String)) : Command")
    text.should contain("generated by `included` (src/parseable.cr:3) expanded at src/sample.cr:2")

    definition = client.definition(URI_A, 0, 9).result.try(&.as_a?)
    definition.try(&.map(&.["uri"].as_s)).should eq(["file://#{root}/src/sample.cr"])
    definition.try(&.map(&.["range"]["start"]["line"].as_i)).should eq([1])
    client.shutdown
  end

  it "answers hover on a def inside an opaque block from the generated def" do
    client = LspClient.in_process
    client.initialize!(root, semantic: fake)
    client.await_notification(Notice::Indexed)
    client.await_stage(Notice::Macros, Stage::Done)

    client.open(URI_A, <<-CR)
      class Command
        resource :x do
          def self.parse(args : Array(String)) : Command
          end
        end
      end
      CR
    client.await_diagnostics
    text = hover_text(client.hover(URI_A, 2, 13)).to_s
    text.should contain("def self.parse(args : Array(String)) : Command")
    text.should contain("generated by `included` (src/parseable.cr:3) expanded at src/sample.cr:2")
    client.shutdown
  end

  it "types a macro call from the expansion the helper reports" do
    expanding = File.expand_path("../../support/fake_expanding_semantic", __DIR__)
    client = LspClient.in_process
    client.initialize!(root, semantic: expanding)
    client.await_notification(Notice::Indexed)
    client.await_stage(Notice::Macros, Stage::Done)

    uri = "file://#{root}/src/crate.cr"
    client.open(uri, <<-CR)
      class String
        def size : Int32
        end
      end

      class Crate
        macro make(value)
          {{ value }}
        end

        def run : Nil
          make("a").size
        end
      end
      CR
    client.await_diagnostics
    text = hover_text(client.hover(uri, 11, 15)).to_s
    text.should contain("# String")
    text.should contain("def size : Int32")
    client.shutdown
  end

  it "reports a failed expansion and says so in the hover" do
    client = LspClient.in_process
    client.initialize!(root, semantic: failing)
    client.await_notification(Notice::Indexed)
    status = client.await_stage(Notice::Macros, Stage::Stale)
    status.params.try(&.["reason"].as_s).to_s.should contain("undefined constant Parseable")

    client.open(URI_A, "Command.parse(ARGV)\n")
    client.await_diagnostics
    hover_text(client.hover(URI_A, 0, 9)).to_s.should contain(
      "no `parse` indexed on Command.class; macros could not be expanded (undefined constant"
    )
    client.shutdown
  end
end

describe Heucristic::Server::Loop, "references" do
  it "lists every call that resolves to the def under the cursor across open documents" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification(Notice::Indexed)

    client.open(URI_A, <<-CR)
      class Greeter
        def greet(name : String) : String
          name
        end

        def twice(name : String) : String
          greet(name) + greet(name)
        end
      end

      class Other
        def greet(name : String) : String
          name
        end
      end
      CR
    client.await_diagnostics
    client.open(URI_B, "Greeter.new.greet(\"x\")\nOther.new.greet(\"y\")\n")
    client.await_diagnostics

    from_def = client.references(URI_A, 1, 6).result.try(&.as_a?)
    places = from_def.try do |found|
      found.map { |place| {place["uri"].as_s, place["range"]["start"]["line"].as_i} }
    end
    places.try(&.sort!).should eq([{URI_A, 6}, {URI_A, 6}, {URI_B, 0}])

    from_call = client.references(URI_B, 0, 13, include_declaration: true).result.try(&.as_a?)
    from_call.try(&.size).should eq(4)
    client.shutdown
  end

  it "counts a call through the base type as a use of an override" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification(Notice::Indexed)

    client.open(URI_A, <<-CR)
      class Node
        def location : Nil
        end
      end

      class Leaf < Node
        def location : Nil
        end
      end

      def find(node : Node) : Nil
        node.location
      end
      CR
    client.await_diagnostics

    found = client.references(URI_A, 6, 8).result.try(&.as_a?)
    found.try(&.map(&.["range"]["start"]["line"].as_i)).should eq([11])
    client.shutdown
  end

  it "lists uses of a local variable, an instance variable and a type" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification(Notice::Indexed)

    client.open(URI_A, <<-CR)
      class Counter
        @total : Int32

        def initialize : Nil
          @total = 0
        end

        def bump(step : Int32) : Nil
          amount = step
          @total = @total + amount
          amount
        end
      end

      Counter.new
      CR
    client.await_diagnostics

    variable = client.references(URI_A, 8, 5).result.try(&.as_a?)
    variable.try(&.map(&.["range"]["start"]["line"].as_i)).should eq([8, 9, 10])

    ivar = client.references(URI_A, 9, 5).result.try(&.as_a?)
    ivar.try(&.map(&.["range"]["start"]["line"].as_i).sort!).should eq([4, 9, 9])

    type = client.references(URI_A, 14, 1, include_declaration: true).result.try(&.as_a?)
    type.try(&.map(&.["range"]["start"]["line"].as_i).sort!).should eq([0, 14])
    client.shutdown
  end
end

describe Heucristic::Server::Loop, "symbols" do
  it "lists document symbols nested by owner and finds workspace symbols by subsequence" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec")
    client.await_notification(Notice::Indexed)

    client.open(URI_A, <<-CR)
      module Shapes
        LIMIT = 3

        struct Circle
          @radius : Float64

          def initialize(@radius : Float64) : Nil
          end

          def self.unit : Circle
          end

          def area : Float64
          end
        end
      end

      def helper : Nil
      end
      CR
    client.await_diagnostics

    symbols = client.document_symbols(URI_A).result.try(&.as_a?)
    symbols.try(&.map(&.["name"].as_s)).should eq(["Shapes", "helper"])
    shapes = symbols.try(&.[0]["children"].as_a)
    shapes.try(&.map(&.["name"].as_s)).should eq(["Circle", "LIMIT"])
    circle = shapes.try(&.[0]["children"].as_a)
    circle.try(&.map(&.["name"].as_s)).should eq(["initialize", "self.unit", "area", "@radius"])
    circle.try(&.map(&.["kind"].as_i)).should eq([9, 6, 6, 8])

    found = client.workspace_symbols("crl").result.try(&.as_a?)
    found.try(&.map(&.["name"].as_s)).should eq(["Shapes::Circle"])
    area = client.workspace_symbols("area").result.try(&.as_a?)
    area.try(&.[0]["containerName"].as_s).should eq("Shapes::Circle")
    client.shutdown
  end
end

describe Heucristic::Server::Loop, "accessor references" do
  it "finds the uses of a getter from the getter declaration" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification(Notice::Indexed)

    client.open(URI_A, <<-CR)
      module Options
        getter date : String?
      end

      struct Command
        include Options

        def run : Nil
          date || "today"
        end
      end
      CR
    client.await_diagnostics

    hover_text(client.hover(URI_A, 1, 10)).to_s.should contain("def date : String?")
    found = client.references(URI_A, 1, 10).result.try(&.as_a?)
    found.try(&.map(&.["range"]["start"]["line"].as_i)).should eq([8])
    client.shutdown
  end
end

describe Heucristic::Server::Loop, "references from synthesized declarations" do
  it "finds uses from a record field and from a delegate name" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification(Notice::Indexed)

    client.open(URI_A, <<-CR)
      record Point, x : Int32, y : Int32

      class Holder
        delegate :x, to: point

        def initialize(@point : Point) : Nil
        end

        def point : Point
          @point
        end

        def run : Int32
          point.x + x
        end
      end
      CR
    client.await_diagnostics

    field = client.references(URI_A, 0, 14).result.try(&.as_a?)
    field.try(&.map(&.["range"]["start"]["character"].as_i)).should eq([10])
    delegated = client.references(URI_A, 3, 12).result.try(&.as_a?)
    delegated.try(&.map(&.["range"]["start"]["character"].as_i)).should eq([14])
    client.shutdown
  end
end

describe Heucristic::Server::Loop, "workspace symbol reopenings" do
  it "lists a type reopened in several files once, at its primary declaration" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec")
    client.await_notification(Notice::Indexed)

    client.open(URI_A, "module App\n  class Runner\n    def go : Nil\n    end\n  end\nend\n")
    client.await_diagnostics
    client.open(URI_B, "module App\n  class Helper\n  end\nend\n")
    client.await_diagnostics

    found = client.workspace_symbols("App").result.try(&.as_a?)
    apps = found.try(&.select { |symbol| symbol["name"].as_s == "App" })
    apps.try(&.size).should eq(1)
    apps.try(&.[0]["location"]["uri"].as_s).should eq(URI_A)
    client.shutdown
  end
end

describe Heucristic::Server::Loop, "completion" do
  it "completes methods after a dot, locals and methods without a receiver, and constants" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec")
    client.await_notification(Notice::Indexed)

    client.open(URI_A, <<-CR)
      module Shapes
        class Circle
          def area : Float64
          end

          def grow(amount : Float64) : Nil
            grown = amount
            self.ar
            gr
            Sha
          end
        end
      end
      CR
    client.await_diagnostics

    completion_labels(client.completion(URI_A, 7, 14)).should eq(["area"])
    completion_labels(client.completion(URI_A, 8, 8)).should eq(["grow", "grown"])
    completion_labels(client.completion(URI_A, 9, 9)).should eq(["Shapes"])
    detail = client.completion(URI_A, 7, 14).result.try(&.["items"][0]["detail"].as_s)
    detail.should eq("def area : Float64")
    client.shutdown
  end
end

describe Heucristic::Server::Loop, "rename" do
  it "renames a def, an instance variable and a type across documents" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec")
    client.await_notification(Notice::Indexed)

    client.open(URI_A, <<-CR)
      module Shapes
        class Circle
          @radius : Int32

          def initialize(@radius : Int32) : Nil
          end

          def area : Int32
            @radius
          end
        end
      end
      CR
    client.await_diagnostics
    client.open(URI_B, "Shapes::Circle.new(1).area\n")
    client.await_diagnostics

    edit = client.rename(URI_A, 7, 9, "surface").result
    changes = edit.try(&.["changes"])
    changes.try(&.[URI_A].as_a.size).should eq(1)
    changes.try(&.[URI_B].as_a.map(&.["newText"].as_s)).should eq(["surface"])
    changes.try(&.[URI_B].as_a.map(&.["range"]["start"]["character"].as_i)).should eq([22])

    ivar = client.rename(URI_A, 8, 7, "size").result
    ivar.try(&.["changes"][URI_A].as_a.map(&.["newText"].as_s).uniq!).should eq(["@size"])
    ivar.try(&.["changes"][URI_A].as_a.size).should eq(3)

    type = client.rename(URI_B, 0, 10, "Disc").result
    renamed = type.try(&.["changes"][URI_B].as_a)
    renamed.try(&.map(&.["range"]["start"]["character"].as_i)).should eq([8])
    renamed.try(&.map(&.["newText"].as_s)).should eq(["Disc"])
    type.try(&.["changes"][URI_A].as_a.map(&.["range"]["start"]["line"].as_i)).should eq([1])

    rejected = client.rename(URI_A, 7, 9, "not valid").error
    rejected.try(&.["message"].as_s).to_s.should contain("not a valid name")
    client.shutdown
  end
end

describe Heucristic::Server::Loop, "completion insert text" do
  it "inserts a bare name for methods without required arguments and a snippet otherwise" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec")
    client.await_notification(Notice::Indexed)

    client.open(URI_A, <<-CR)
      class Clock
        def time : Int32
        end

        def shift(hours : Int32, minutes : Int32 = 0) : Int32
        end

        def run : Nil
          self.
        end
      end
      CR
    client.await_diagnostics

    items = client.completion(URI_A, 8, 9).result.try(&.["items"].as_a)
    by_label = items.try(&.to_h { |item| {item["label"].as_s, item} })
    by_label.try(&.["time"]["insertText"].as_s).should eq("time")
    by_label.try(&.["time"]["kind"].as_i).should eq(10)
    by_label.try(&.["shift"]["insertText"].as_s).should eq("shift(${1:hours})")
    by_label.try(&.["shift"]["insertTextFormat"].as_i).should eq(2)
    client.shutdown
  end
end

describe Heucristic::Server::Loop, "type declarations under the cursor" do
  it "resolves the name of a class definition for hover, references and rename" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec")
    client.await_notification(Notice::Indexed)

    client.open(URI_A, "module App\n  class Context\n  end\nend\n\nApp::Context.new\n")
    client.await_diagnostics

    hover_text(client.hover(URI_A, 1, 10)).to_s.should contain("class App::Context")
    found = client.references(URI_A, 1, 10).result.try(&.as_a?)
    found.try(&.map(&.["range"]["start"]["line"].as_i)).should eq([5])
    edit = client.rename(URI_A, 1, 10, "Session").result
    lines = edit.try(&.["changes"][URI_A].as_a.map(&.["range"]["start"]["line"].as_i))
    lines.try(&.sort!).should eq([1, 5])
    client.shutdown
  end
end

describe Heucristic::Server::Loop, "compiler diagnostics" do
  root = File.expand_path("../../fixtures/compiler", __DIR__)
  fake = File.expand_path("../../support/fake_compiler", __DIR__)
  broken_uri = "file://#{root}/src/broken.cr"

  it "publishes the innermost project frame of a compiler error as an error from crystal" do
    client = LspClient.in_process
    client.initialize!(root, compiler: fake)
    client.await_notification(Notice::Indexed)
    client.await_stage(Notice::Compiler, Stage::Done)

    client.open(broken_uri, File.read(File.join(root, "src", "broken.cr")))
    client.await_diagnostics

    frames = [
      {file: "#{root}/src/broken.cr", line: 7, column: 13, size: 0,
       message: "instantiating 'Counter#bump(String)'"},
      {file: "/opt/stdlib/int.cr", line: 3, column: 1, size: 0, message: "deep inside"},
    ]
    ENV["HEUCRISTIC_FAKE_ERRORS"] = frames.to_json
    client.save(broken_uri)
    published = client.await_diagnostics
    diagnostics = published.params.try(&.["diagnostics"].as_a) || Array(JSON::Any).new
    published.params.try(&.["uri"].as_s).should eq(broken_uri)
    diagnostics.size.should eq(1)
    diagnostics[0]["source"].as_s.should eq("crystal")
    diagnostics[0]["severity"].as_i.should eq(1)
    diagnostics[0]["message"].as_s.should eq("instantiating 'Counter#bump(String)'")
    diagnostics[0]["range"]["start"]["line"].as_i.should eq(6)
    diagnostics[0]["range"]["start"]["character"].as_i.should eq(12)
    diagnostics[0]["range"]["end"]["character"].as_i.should eq(16)
    status = client.await_stage(Notice::Compiler, Stage::Done).params
    status.try(&.["errors"].as_i).should eq(1)
    status.try(&.["file"].as_s).should eq("#{root}/src/broken.cr")
    status.try(&.["line"].as_i).should eq(7)
    status.try(&.["message"].as_s).should eq("instantiating 'Counter#bump(String)'")

    ENV.delete("HEUCRISTIC_FAKE_ERRORS")
    client.save(broken_uri)
    cleared = client.await_diagnostics
    cleared.params.try(&.["diagnostics"].as_a.size).should eq(0)
    client.shutdown
  end

  it "places a macro raise on the frame that carries the message rather than the entry" do
    client = LspClient.in_process
    client.initialize!(root, compiler: fake)
    client.await_notification(Notice::Indexed)
    client.await_stage(Notice::Compiler, Stage::Done)

    client.open(broken_uri, File.read(File.join(root, "src", "broken.cr")))
    client.await_diagnostics

    frames = [
      {file: "#{root}/src/broken.cr", line: 2, column: 5, size: 0, message: "unknown platform"},
      {file: "#{root}/src/broken.cr", line: 7, column: 1, size: 0, message: "unknown platform"},
    ]
    ENV["HEUCRISTIC_FAKE_ERRORS"] = frames.to_json
    client.save(broken_uri)
    published = client.await_diagnostics
    diagnostics = published.params.try(&.["diagnostics"].as_a) || Array(JSON::Any).new
    diagnostics.map(&.["range"]["start"]["line"].as_i).should eq([1])
    ENV.delete("HEUCRISTIC_FAKE_ERRORS")
    client.shutdown
  end

  it "reports a compiler that cannot run and says why" do
    client = LspClient.in_process
    client.initialize!(root, compiler: "/nonexistent/crystal")
    client.await_notification(Notice::Indexed)
    status = client.await_stage(Notice::Compiler, Stage::Unavailable)
    status.params.try(&.["reason"].as_s).to_s.should contain("not found")
    client.shutdown
  end

  it "runs the real compiler against the fixture and places its error", tags: "compiler" do
    client = LspClient.in_process
    client.initialize!(root)
    client.await_notification(Notice::Indexed)
    published = client.await_diagnostics(60.seconds)
    published.params.try(&.["uri"].as_s).should eq(broken_uri)
    diagnostics = published.params.try(&.["diagnostics"].as_a) || Array(JSON::Any).new
    diagnostics.size.should eq(1)
    diagnostics[0]["message"].as_s.should contain(
      "expected argument #1 to 'Counter#bump' to be Int32, not String"
    )
    diagnostics[0]["range"]["start"]["line"].as_i.should eq(6)
    client.shutdown
  end
end

describe Heucristic::Server::Loop, "call checks" do
  root = File.expand_path("../../fixtures/checks", __DIR__)
  semantic = File.expand_path("../../support/checks_semantic", __DIR__)
  compiler = File.expand_path("../../support/fake_compiler", __DIR__)
  usage_uri = "file://#{root}/src/usage.cr"

  it "warns about undefined methods, wrong arity and block mismatches once macros are settled" do
    client = LspClient.in_process
    client.initialize!(root, stdlib: true, semantic: semantic, compiler: compiler)
    client.await_notification(Notice::Indexed, 60.seconds)
    client.await_stage(Notice::Macros, Stage::Done, 60.seconds)

    client.open(usage_uri, <<-CR)
      greeter = Greeter.new
      greeter.greet("a")
      greeter.gret("a")
      greeter.greet("a", "b")
      greeter.each_twice
      Greeter.new.each_twice { }
      Point.new(1, 2).copy_with(x: 3)
      Point.new(1)
      missing_thing
      greeter.greet(1)
      greeter.shout("a", 3_i64)
      greeter.shout("a", 3)
      greeter.shout(:a, 3)
      case Clock::Start
      in .start?       then 1
      in .break_start? then 2
      end
      case Clock::Start
      in .start?, .finish?, .break_start? then 1
      end

      class Circle < Shape
      end
      Shape.new
      Array(Int32, String).new
      Greeter(Int32).new
      break

      class Sub < Shape
        def area : Int32
          1
        end

        def wave : Nil
          super
        end

        def solo : Nil
          previous_def
        end

        def flip(flag : Bool) : Int32
          case flag
          in true then 1
          end
        end

        def pick(value : Int32 | String) : Int32
          case value
          in Int32 then 1
          end
        end
      end
      greeter.config(1, key: "a", other: 2)
      greeter.config(1)
      greeter.config(1, a: 2, key: "x")
      greeter.config(1, key: "a")
      Nope.new
      Greeter::Missing
      Point::X

      class Sizes
        def other : String
          1 + 1
        end

        def wide : Int32
          Greeter.new.greet("a")
        end

        def label : String
        end

        def either(flag : Bool) : Int32
          return "no" if flag

          1
        end
      end

      class Gauge
        @level : Int32
        @label : String?
        @count : Int32 = 0

        def initialize(@label : String?)
        end

        def bump : Nil
          @level = "x"
          @missing
          @count = 2
        end
      end
      greeter.secret
      greeter.guarded
      numbers = [1, 2]
      greeter.greet(numbers)
      twice("a", "b")
      twice("a")
      class Gauge
        def name : String
          @label
        end

        def announce : Nil
          Greeter.new.greet(@label)
        end

        def maybe : String
          Greeter.new.optional
        end
      end
      build do
        add("x")
        add(1)
        adx("x")
        puts "ok"
        greeter.configure_with do
          greet("a")
          greet(1)
        end
      end
      def use(shape : Shape) : Int32
        shape.area(1)
      end
      wrap do
        Greeter.new.gret("b")
      end
      channel = Channel(Int32).new
      picked = select
      when number = channel.receive
        number
      when timeout(1.second)
        raise "late"
      end
      picked.gret
      spawn do
        Greeter.new.gret("d")
      end
      def maybe_shape(shape : Shape?) : Nil
        shape.gret
      end
      def widen(count : Int64) : Nil
      end
      narrow_count = 3
      widen(narrow_count)
      case Shop::BarColor::Green
      in Color::Red then 1
      in .green?    then 2
      end
      CR
    warnings = client.await_diagnostics(usage_uri) { |found| found.size == 45 }
    warnings.all? { |warning| warning["severity"].as_i == 2 }.should be_true
    warnings.all? { |warning| warning["source"].as_s == "heucristic" }.should be_true
    reported = warnings.map do |warning|
      {warning["range"]["start"]["line"].as_i, warning["code"].as_s, warning["message"].as_s}
    end
    reported.should eq([
      {2, "undefined-method", "undefined method 'gret' for Greeter"},
      {3, "wrong-arity", "wrong number of arguments for 'Greeter#greet' (given 2, expected 1)"},
      {4, "block-mismatch",
       "'Greeter#each_twice' is expected to be invoked with a block, but no block was given"},
      {7, "wrong-arity", "wrong number of arguments for 'Point#initialize' (given 1, expected 2)"},
      {8, "undefined-method", "undefined local variable or method 'missing_thing' for top-level"},
      {9, "type-mismatch", "expected argument #1 to 'Greeter#greet' to be String, not Int32"},
      {12, "type-mismatch", "expected argument #1 to 'Greeter#shout' to be String, not Symbol"},
      {13, "non-exhaustive-case",
       "case is not exhaustive for enum Clock.\n\nMissing members:\n - Finish"},
      {21, "abstract-not-implemented", "abstract `def Shape#area()` must be implemented by Circle"},
      {23, "abstract-instantiated", "can't instantiate abstract class Shape"},
      {24, "wrong-type-arguments", "wrong number of type vars for Array(T) (given 2, expected 1)"},
      {25, "not-generic", "Greeter is not a generic type, it's a class"},
      {26, "misplaced-control", "invalid break"},
      {34, "no-superclass-method", "undefined method 'wave' for Object"},
      {38, "no-previous-def", "there is no previous definition of 'solo'"},
      {42, "non-exhaustive-case", "case is not exhaustive.\n\nMissing cases:\n - false"},
      {48, "non-exhaustive-case", "case is not exhaustive.\n\nMissing cases:\n - String"},
      {53, "named-argument", "no parameter named 'other'"},
      {54, "named-argument", "missing argument: key"},
      {55, "named-argument", "argument for parameter 'a' already specified"},
      {57, "undefined-constant", "undefined constant Nope"},
      {58, "undefined-constant", "undefined constant Greeter::Missing"},
      {59, "undefined-constant", "undefined constant Point::X"},
      {63, "return-mismatch", "method Sizes#other must return String but it is returning Int32"},
      {67, "return-mismatch", "method Sizes#wide must return Int32 but it is returning String"},
      {70, "return-mismatch", "method Sizes#label must return String but it is returning Nil"},
      {74, "return-mismatch", "method Sizes#either must return Int32 but it is returning String"},
      {85, "uninitialized-instance-var",
       "this 'initialize' doesn't explicitly initialize instance variable '@level' of Gauge, " \
       "rendering it nilable"},
      {89, "instance-var-mismatch",
       "instance variable '@level' of Gauge must be Int32, not String"},
      {90, "unknown-instance-var", "can't infer the type of instance variable '@missing' of Gauge"},
      {94, "private-call", "private method 'secret' called for Greeter"},
      {95, "protected-call", "protected method 'guarded' called for Greeter"},
      {97, "type-mismatch",
       "expected argument #1 to 'Greeter#greet' to be String, not Array(Int32)"},
      {98, "macro-argument", "wrong number of arguments for macro 'twice' (given 2, expected 1)"},
      {102, "return-mismatch",
       "method Gauge#name must return String but it is returning String | Nil"},
      {106, "type-mismatch",
       "expected argument #1 to 'Greeter#greet' to be String, not String | Nil"},
      {115, "type-mismatch", "expected argument #1 to 'Builder#add' to be String, not Int32"},
      {116, "undefined-method", "undefined local variable or method 'adx' for top-level"},
      {120, "type-mismatch", "expected argument #1 to 'Greeter#greet' to be String, not Int32"},
      {124, "wrong-arity", "wrong number of arguments for 'Shape#area' (given 1, expected 0)"},
      {127, "undefined-method", "undefined method 'gret' for Greeter"},
      {136, "undefined-method", "undefined method 'gret' for Int32"},
      {138, "undefined-method", "undefined method 'gret' for Greeter"},
      {141, "undefined-on-member",
       "undefined method 'gret' for Shape (compile-time type is (Shape | Nil))"},
      {147, "non-exhaustive-case",
       "case is not exhaustive for enum Shop::BarColor.\n\nMissing members:\n - Red"},
    ])

    frames = [{file: "#{root}/src/usage.cr", line: 4, column: 9, size: 0, message: "boom"}]
    ENV["HEUCRISTIC_FAKE_ERRORS"] = frames.to_json
    client.save(usage_uri)
    merged = client.await_diagnostics(usage_uri) do |found|
      found.any? { |entry| entry["source"].as_s == "crystal" } && found.size == 45
    end
    ENV.delete("HEUCRISTIC_FAKE_ERRORS")
    on_line = merged.select { |entry| entry["range"]["start"]["line"].as_i == 3 }
    on_line.map(&.["severity"].as_i).should eq([1])
    client.shutdown
  end

  it "ignores an abstract def declared in a file the compiler never loaded" do
    client = LspClient.in_process
    client.initialize!(root, stdlib: true, semantic: semantic, compiler: compiler)
    client.await_notification(Notice::Indexed, 60.seconds)
    client.await_stage(Notice::Macros, Stage::Done, 60.seconds)

    pages_uri = "file://#{root}/app/pages.cr"
    found = client.await_diagnostics(pages_uri, 60.seconds) { |published| !published.empty? }
    found.map(&.["code"].as_s).should eq(["undefined-method"])
    client.shutdown
  end

  it "reports a non-exhaustive case over a file-private enum from the sweep" do
    client = LspClient.in_process
    client.initialize!(root, stdlib: true, semantic: semantic, compiler: compiler)
    client.await_notification(Notice::Indexed, 60.seconds)
    client.await_stage(Notice::Macros, Stage::Done, 60.seconds)

    checks_uri = "file://#{root}/src/checks.cr"
    found = client.await_diagnostics(checks_uri, 60.seconds) do |published|
      published.any?(&.["message"].as_s.includes?("enum Mood"))
    end
    missing = found.select(&.["message"].as_s.includes?("enum Mood"))
    missing.map(&.["code"].as_s).should eq(["non-exhaustive-case"])
    missing[0]["message"].as_s.should eq(
      "case is not exhaustive for enum Mood.\n\nMissing members:\n - Down"
    )
    client.shutdown
  end

  it "expands the spec tree's macros once a file under spec is opened" do
    client = LspClient.in_process
    client.initialize!(root, stdlib: true, semantic: semantic)
    client.await_notification(Notice::Indexed, 60.seconds)
    client.await_stage(Notice::Macros, Stage::Done, 60.seconds)

    spec_path = File.join(root, "spec", "checks_spec.cr")
    client.open("file://#{spec_path}", File.read(spec_path))
    status = client.await_stage(Notice::Macros, Stage::Done, 60.seconds)
    status.params.try(&.["target"].as_s).should eq("spec")
    client.shutdown
  end

  it "explains calls inside macro arguments and describes a macro on hover" do
    client = LspClient.in_process
    client.initialize!(root, stdlib: true, semantic: semantic)
    client.await_notification(Notice::Indexed, 60.seconds)
    client.await_stage(Notice::Macros, Stage::Done, 60.seconds)

    client.open(usage_uri, "pick do\n  inner { Greeter.new.greet(\"a\") }\nend\ntwice(1)\n")
    client.await_diagnostics

    hover_text(client.hover(usage_uri, 1, 3)).to_s.should eq(
      "`inner` is syntax of the `pick` macro at src/checks.cr:39, not a method call"
    )
    hover_text(client.hover(usage_uri, 1, 23)).to_s.should contain("def greet(name : String)")
    hover_text(client.hover(usage_uri, 3, 1)).to_s.should eq("```crystal\nmacro twice(text)\n```")
    definition = client.definition(usage_uri, 3, 1).result.try(&.as_a?)
    definition.try(&.map(&.["range"]["start"]["line"].as_i)).should eq([42])
    client.shutdown
  end

  it "drops a warning as soon as the edited document defines the method" do
    client = LspClient.in_process
    client.initialize!(root, stdlib: true, semantic: semantic)
    client.await_notification(Notice::Indexed, 60.seconds)
    client.await_stage(Notice::Macros, Stage::Done, 60.seconds)

    client.open(usage_uri, "Greeter.new.gret(\"a\")\n")
    client.await_diagnostics(usage_uri) { |found| found.size == 1 }

    range = {"start" => {"line" => 1, "character" => 0}, "end" => {"line" => 1, "character" => 0}}
    addition = "class Greeter\n  def gret(name : String) : String\n    name\n  end\nend\n"
    client.change(usage_uri, 2, [{"range" => range, "text" => addition}])
    client.await_diagnostics(usage_uri, &.empty?)
    client.shutdown
  end

  it "resolves a file-private type in the in branches of a case over a union" do
    client = LspClient.in_process
    client.initialize!(root, stdlib: true, semantic: semantic)
    client.await_notification(Notice::Indexed, 60.seconds)
    client.await_stage(Notice::Macros, Stage::Done, 60.seconds)

    client.open(usage_uri, <<-CR)
      private class Secret
      end

      def pick(value : Secret | String | Int32) : Nil
        case value
        in Secret, Int32
          1
        end
      end
      CR
    warnings = client.await_diagnostics(usage_uri) { |found| found.size == 1 }
    reported = warnings.map do |warning|
      {warning["range"]["start"]["line"].as_i, warning["code"].as_s, warning["message"].as_s}
    end
    reported.should eq([
      {4, "non-exhaustive-case", "case is not exhaustive.\n\nMissing cases:\n - String"},
    ])
    client.shutdown
  end
end

describe Heucristic::Server::Loop, "requires" do
  root = File.expand_path("../../fixtures/checks", __DIR__)
  usage_uri = "file://#{root}/src/usage.cr"

  it "jumps from a require to the files it loads and explains one that matches nothing" do
    client = LspClient.in_process
    client.initialize!(root)
    client.await_notification(Notice::Indexed)

    client.open(usage_uri, <<-CR)
      require "./checks"
      require "./nope"
      require "json"
      require "./*"
      CR
    client.await_diagnostics

    checks = File.join(root, "src", "checks.cr")
    targets = client.definition(usage_uri, 0, 10).result.try(&.as_a.map(&.["uri"].as_s))
    targets.should eq(["file://#{checks}"])
    hover_text(client.hover(usage_uri, 0, 10)).to_s.should contain(checks)

    hover_text(client.hover(usage_uri, 1, 3)).to_s.should contain(
      "no file matches `require \"./nope\"`, tried:\n- `#{File.join(root, "src", "nope.cr")}`"
    )
    client.definition(usage_uri, 1, 3).result.try(&.raw).should be_nil

    stdlib = client.definition(usage_uri, 2, 9).result.try(&.as_a.map(&.["uri"].as_s))
    stdlib.try(&.size).should eq(1)
    stdlib.try(&.[0].ends_with?("/json.cr")).should be_true

    globbed = client.definition(usage_uri, 3, 0).result.try(&.as_a.map(&.["uri"].as_s))
    globbed.should eq(["file://#{checks}"])
    client.shutdown
  end

  it "completes require strings from the requiring file's directory and the crystal path" do
    client = LspClient.in_process
    client.initialize!(root)
    client.await_notification(Notice::Indexed)

    client.open(usage_uri, "require \"./ch\"\nrequire \"js\"\nrequire \"./\"\n")
    client.await_diagnostics

    completion_labels(client.completion(usage_uri, 0, 13)).should eq(["checks"])
    edit = client.completion(usage_uri, 0, 13).result.try(&.["items"][0]["textEdit"])
    edit.try(&.["range"]["start"]["character"].as_i).should eq(11)
    edit.try(&.["newText"].as_s).should eq("checks")
    completion_labels(client.completion(usage_uri, 1, 11)).try(&.includes?("json")).should be_true
    completion_labels(client.completion(usage_uri, 2, 11)).should eq(["checks"])
    client.shutdown
  end
end

describe Heucristic::Server::Loop, "shard targets" do
  root = File.expand_path("../../fixtures/targets", __DIR__)
  picky = File.expand_path("../../support/picky_semantic", __DIR__)

  it "lists every target's main and compiles the first one for the compiler lane" do
    mains = Heucristic::Server::EntryFile.mains(root)
    mains.should eq([File.join(root, "src", "good.cr"), File.join(root, "src", "broken.cr")])
    Heucristic::Server::EntryFile.find(root).should eq(File.join(root, "src", "good.cr"))
  end

  it "leaves a target whose expansion fails out of the combined entry and says so" do
    client = LspClient.in_process
    client.initialize!(root, semantic: picky)
    client.await_notification(Notice::Indexed)
    status = client.await_stage(Notice::Macros, Stage::Done)
    reason = status.params.try(&.["reason"].as_s).to_s
    reason.should contain("left out of the expansion because it failed: src/broken.cr")
    reason.should contain("(undefined local variable or method 'undefined_thing')")
    client.shutdown
  end
end
