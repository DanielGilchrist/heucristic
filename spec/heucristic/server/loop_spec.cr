require "../../spec_helper"

private URI_A = "file:///tmp/heucristic-spec/a.cr"

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

  it "answers null for a call with a receiver" do
    client = LspClient.in_process
    client.initialize!("/tmp/heucristic-spec-empty")
    client.await_notification("$/heucristic/indexed")

    client.open(URI_A, "x = 1\nx.abs\n")
    client.await_notification("textDocument/publishDiagnostics")

    client.hover(URI_A, 1, 2).result.try(&.raw).should be_nil
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
    hover_text(client.hover(URI_A, 9, 6)).to_s.should contain("class Outer::Thing")
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
end
