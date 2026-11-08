require "../../spec_helper"

private URI_A = "file:///tmp/heucristic-spec/a.cr"

private def hover_text(response : Heucristic::Protocol::Response) : String?
  response.result.try(&.["contents"]?).try(&.["value"]?).try(&.as_s?)
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
end
