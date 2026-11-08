require "../../spec_helper"

private URI_A = "file:///tmp/heucristic-spec/a.cr"

private def hover_text(response : Heucristic::Protocol::Response) : String?
  response.result.try(&.["contents"]?).try(&.["value"]?).try(&.as_s?)
end

private def starts(response : Heucristic::Protocol::Response) : Array({Int32, Int32})?
  response.result.try(&.as_a?).try do |locations|
    locations.map do |location|
      start = location["range"]["start"]
      {start["line"].as_i, start["character"].as_i}
    end
  end
end

private def with_document(source : String, & : LspClient ->) : Nil
  client = LspClient.in_process
  client.initialize!("/tmp/heucristic-spec-empty")
  client.await_notification(Heucristic::Server::Notice::Indexed)
  client.open(URI_A, source)
  client.await_diagnostics
  yield client
  client.shutdown
end

describe "hover and definition at editor positions" do
  it "describes a namespace that only nested declarations imply, with no definition" do
    source = "class Outer::Inner\nend\n\nx = Outer::Inner\n"
    with_document(source) do |client|
      {client.hover(URI_A, 0, 7), client.hover(URI_A, 3, 5)}.each do |response|
        text = hover_text(response).to_s
        text.should contain("# Outer")
        text.should contain("implied by the declarations nested in it")
        text.should contain("`Outer::Inner` at ")
      end
      client.definition(URI_A, 0, 7).result.try(&.raw).should be_nil
    end
  end

  it "says what a builtin without source is and gives no definition" do
    source = "def stop : NoReturn\n  exit\nend\n"
    with_document(source) do |client|
      text = hover_text(client.hover(URI_A, 0, 13)).to_s
      text.should contain("built into the compiler")
      text.should contain("the type of an expression that never returns")
      client.definition(URI_A, 0, 13).result.try(&.raw).should be_nil
    end
  end

  it "says a compiler constant is provided by the compiler and gives no definition" do
    with_document("x = Crystal::VERSION\ny = Crystal::DESCRIPTION\n") do |client|
      version = hover_text(client.hover(URI_A, 0, 13)).to_s
      version.should contain("provided by the compiler")
      version.should contain("Crystal::VERSION")
      version.should contain("Crystal::VERSION = \"")
      hover_text(client.hover(URI_A, 1, 15)).to_s.should contain("Crystal::DESCRIPTION")
      client.definition(URI_A, 0, 13).result.try(&.raw).should be_nil
    end
  end

  it "hovers and jumps from the name of an alias declaration" do
    with_document("alias Query = Hash(String, String)\n") do |client|
      text = hover_text(client.hover(URI_A, 0, 7)).to_s
      text.should contain("alias Query = Hash(String, String)")
      client.definition(URI_A, 0, 7).result.try(&.as_a?).try(&.size).should eq(1)
    end
  end

  it "jumps from a rescue variable to the rescue clause that binds it" do
    source = "def run\n  exit\nrescue ex : Exception\n  ex.message\nrescue boom\n  boom\nend\n"
    with_document(source) do |client|
      starts(client.definition(URI_A, 3, 3)).should eq([{2, 7}])
      starts(client.definition(URI_A, 5, 3)).should eq([{4, 7}])
    end
  end

  it "jumps from a variable captured by a proc literal to the enclosing def's declaration" do
    source = "def run(user_id : Int32)\n  window = 1\n  -> : Int32 { window + user_id }\nend\n"
    with_document(source) do |client|
      starts(client.definition(URI_A, 2, 15)).should eq([{1, 2}])
      starts(client.definition(URI_A, 2, 24)).should eq([{0, 8}])
    end
  end
end
