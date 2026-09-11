require "../../spec_helper"

private URI_A = "file:///tmp/heucristic-spec/a.cr"
private URI_B = "file:///tmp/heucristic-spec/b.cr"

private def hover_text(response : Heucristic::Protocol::Response) : String?
  response.result.try(&.["contents"]?).try(&.["value"]?).try(&.as_s?)
end

describe Heucristic::Server::Loop do
  it "initializes and reports hover and definition capabilities" do
    client = LspClient.in_process
    response = client.initialize!(Dir.current)
    capabilities = response.result.try(&.["capabilities"]?)
    capabilities.try(&.["hoverProvider"]?).try(&.as_bool?).should be_true
    capabilities.try(&.["definitionProvider"]?).try(&.as_bool?).should be_true
    client.await_notification("$/heucristic/indexed", 30.seconds)
    client.shutdown
  end

  it "publishes a syntax error and clears it after a fixing edit" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification("$/heucristic/indexed")

    client.open(URI_A, "def foo(\nend\n")
    published = client.await_notification("textDocument/publishDiagnostics")
    published.params.try(&.["diagnostics"]?).try(&.as_a?).try(&.size).should eq(1)

    range = {"start" => {"line" => 0, "character" => 7}, "end" => {"line" => 0, "character" => 8}}
    client.change(URI_A, 2, [{"range" => range, "text" => ""}])
    cleared = client.await_notification("textDocument/publishDiagnostics")
    cleared.params.try(&.["diagnostics"]?).try(&.as_a?).try(&.size).should eq(0)
    cleared.params.try(&.["version"]?).try(&.as_i?).should eq(2)
    client.shutdown
  end

  it "answers hover and definition for a receiverless call from the open document" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification("$/heucristic/indexed")

    client.open(URI_A, "def greet(name : String) : String\n  name\nend\n\ngreet(\"x\")\n")
    client.await_notification("textDocument/publishDiagnostics")

    hover_text(client.hover(URI_A, 4, 1)).to_s.should contain("def greet(name : String) : String")
    definition = client.definition(URI_A, 4, 1).result.try(&.as_a?)
    definition.try(&.size).should eq(1)
    definition.try(&.[0]["range"]["start"]["line"].as_i).should eq(0)
    definition.try(&.[0]["range"]["start"]["character"].as_i).should eq(4)
    client.shutdown
  end

  it "explains a call it cannot resolve and gives no definition" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification("$/heucristic/indexed")

    client.open(URI_A, "x = 1\nx.abs\n")
    client.await_notification("textDocument/publishDiagnostics")

    hover_text(client.hover(URI_A, 1, 2)).to_s.should eq("no `abs` indexed on Int32")
    client.definition(URI_A, 1, 2).result.try(&.raw).should be_nil
    client.shutdown
  end

  it "rejects an unknown method with method not found" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    response = client.request("textDocument/rename", {"x" => 1})
    response.error.try(&.["code"]?).try(&.as_i?).should eq(-32601)
    client.shutdown
  end

  it "resolves a constant through the enclosing namespaces and lists every reopening" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification("$/heucristic/indexed")

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
    client.await_notification("textDocument/publishDiagnostics")

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
    client.await_notification("$/heucristic/indexed")

    client.open(URI_A, "alias Broken = Missing | Nil\n\ndef f(x : Broken)\nend\n")
    client.await_notification("textDocument/publishDiagnostics")

    definition = client.definition(URI_A, 2, 11).result.try(&.as_a?)
    definition.try(&.map(&.["range"]["start"]["line"].as_i)).should eq([0])
    hover_text(client.hover(URI_A, 2, 11)).to_s.should contain("alias Broken = Missing | Nil")
    client.shutdown
  end

  it "resolves an implicit self call to the enclosing type instead of the whole workspace" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification("$/heucristic/indexed")

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
    client.await_notification("textDocument/publishDiagnostics")

    definition = client.definition(URI_A, 10, 5).result.try(&.as_a?)
    definition.try(&.map(&.["range"]["start"]["line"].as_i)).should eq([6])
    client.shutdown
  end

  it "shows a parameter's declared type on hover and jumps to the parameter" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification("$/heucristic/indexed")

    source = "class Box\n  def fill(item : String, other) : Nil\n    item\n    other\n  end\nend\n"
    client.open(URI_A, source)
    client.await_notification("textDocument/publishDiagnostics")

    hover_text(client.hover(URI_A, 2, 5)).to_s.should eq("```crystal\nString\n```")
    hover_text(client.hover(URI_A, 3, 5)).to_s.should contain("no type restriction")
    definition = client.definition(URI_A, 2, 5).result.try(&.as_a?)
    definition.try(&.map(&.["range"]["start"]["character"].as_i)).should eq([11])
    client.shutdown
  end

  it "explains why a call cannot be resolved instead of guessing" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification("$/heucristic/indexed")

    client.open(URI_A, "def go(x)\n  x.size\nend\n")
    client.await_notification("textDocument/publishDiagnostics")

    hover_text(client.hover(URI_A, 1, 5)).to_s.should contain("parameter x has no type restriction")
    client.definition(URI_A, 1, 5).result.try(&.raw).should be_nil
    client.shutdown
  end

  it "types an ivar assigned with Const.new and resolves a call on it" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification("$/heucristic/indexed")

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
    client.await_notification("textDocument/publishDiagnostics")

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
      value = client.await_notification("$/progress").params.try(&.["value"]?)
      kinds << value.try(&.["kind"]?).try(&.as_s?).to_s
    end
    kinds.first.should eq("begin")
    kinds.last.should eq("end")
    client.shutdown
  end

  it "stays silent about progress when the client does not support it" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    indexed = client.await_notification("$/heucristic/indexed")
    (indexed.params.try(&.["files"]?).try(&.as_i?) || -1).should be < 10
    client.shutdown
  end

  it "indexes the stdlib on request and resolves a call on a string literal" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty", stdlib: true)
    indexed = client.await_notification("$/heucristic/indexed", 60.seconds)
    (indexed.params.try(&.["files"]?).try(&.as_i?) || 0).should be > 1000

    client.open(URI_A, "\"x\".size\n")
    client.await_notification("textDocument/publishDiagnostics")

    hover_text(client.hover(URI_A, 0, 5)).to_s.should contain("String#size")
    client.shutdown
  end

  it "resolves a constant through its namespace and shows its value" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification("$/heucristic/indexed")

    client.open(URI_A, "module Fibers\n  WORKERS = 4\nend\n\nx = Fibers::WORKERS\n")
    client.await_notification("textDocument/publishDiagnostics")

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
    client.await_notification("$/heucristic/indexed")

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
    client.await_notification("textDocument/publishDiagnostics")

    hover_text(client.hover(URI_A, 7, 13)).to_s.should contain("def receive : String | Nil")
    client.shutdown
  end

  it "resolves an enum member and the enum itself from one path" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification("$/heucristic/indexed")

    client.open(URI_A, "enum Kind\n  Splat\nend\n\nx = Kind::Splat\n")
    client.await_notification("textDocument/publishDiagnostics")

    hover_text(client.hover(URI_A, 4, 10)).to_s.should eq("```crystal\nKind::Splat\n```")
    hover_text(client.hover(URI_A, 4, 5)).to_s.should eq("```crystal\nenum Kind\n```")
    definition = client.definition(URI_A, 4, 10).result.try(&.as_a?)
    definition.try(&.map(&.["range"]["start"]["line"].as_i)).should eq([1])
    client.shutdown
  end

  it "always explains a hover it cannot answer" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification("$/heucristic/indexed")

    client.open(URI_A, "x = Missing::Thing\n\n")
    client.await_notification("textDocument/publishDiagnostics")

    hover_text(client.hover(URI_A, 0, 6)).to_s.should eq("unknown (unresolved name: Missing)")
    hover_text(client.hover(URI_A, 1, 0)).to_s.should contain("under the cursor")
    hover_text(client.hover(URI_A, 9, 0)).to_s.should eq("position is outside the document")
    client.definition(URI_A, 0, 6).result.try(&.raw).should be_nil
    client.shutdown
  end

  it "renders the whole signature with the receiver's bindings" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification("$/heucristic/indexed")

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
    client.await_notification("textDocument/publishDiagnostics")

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
    client.await_notification("$/heucristic/indexed")

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
    client.await_notification("textDocument/publishDiagnostics")

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
    client.await_notification("$/heucristic/indexed")
    status = client.await_notification("$/heucristic/macros")
    while status.params.try(&.["status"].as_s) == "pending"
      status = client.await_notification("$/heucristic/macros")
    end
    status.params.try(&.["status"].as_s).should eq("done")
    status.params.try(&.["defs"].as_i).should eq(1)

    client.open(URI_A, "Command.parse(ARGV)\n")
    client.await_notification("textDocument/publishDiagnostics")
    text = hover_text(client.hover(URI_A, 0, 9)).to_s
    text.should contain("def self.parse(args : Array(String)) : Command")
    text.should contain("generated by `included` (src/parseable.cr:3) expanded at src/sample.cr:2")

    definition = client.definition(URI_A, 0, 9).result.try(&.as_a?)
    definition.try(&.map(&.["uri"].as_s)).should eq(["file://#{root}/src/sample.cr"])
    definition.try(&.map(&.["range"]["start"]["line"].as_i)).should eq([1])
    client.shutdown
  end

  it "reports a failed expansion and says so in the hover" do
    client = LspClient.in_process
    client.initialize!(root, semantic: failing)
    client.await_notification("$/heucristic/indexed")
    status = client.await_notification("$/heucristic/macros")
    while status.params.try(&.["status"].as_s) == "pending"
      status = client.await_notification("$/heucristic/macros")
    end
    status.params.try(&.["status"].as_s).should eq("stale")
    status.params.try(&.["reason"].as_s).to_s.should contain("undefined constant Parseable")

    client.open(URI_A, "Command.parse(ARGV)\n")
    client.await_notification("textDocument/publishDiagnostics")
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
    client.await_notification("$/heucristic/indexed")

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
    client.await_notification("textDocument/publishDiagnostics")
    client.open(URI_B, "Greeter.new.greet(\"x\")\nOther.new.greet(\"y\")\n")
    client.await_notification("textDocument/publishDiagnostics")

    from_def = client.references(URI_A, 1, 6).result.try(&.as_a?)
    places = from_def.try do |found|
      found.map { |place| {place["uri"].as_s, place["range"]["start"]["line"].as_i} }
    end
    places.try(&.sort!).should eq([{URI_A, 6}, {URI_A, 6}, {URI_B, 0}])

    from_call = client.references(URI_B, 0, 13, include_declaration: true).result.try(&.as_a?)
    from_call.try(&.size).should eq(4)
    client.shutdown
  end

  it "lists uses of a local variable, an instance variable and a type" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification("$/heucristic/indexed")

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
    client.await_notification("textDocument/publishDiagnostics")

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
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification("$/heucristic/indexed")

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
    client.await_notification("textDocument/publishDiagnostics")

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
