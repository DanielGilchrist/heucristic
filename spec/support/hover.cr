DOCUMENT_URI = "file:///tmp/heucristic-spec/a.cr"

def hover_text(response : Heucristic::Protocol::Response) : String?
  response.result.try(&.as_h?).try(&.["contents"]?).try(&.["value"]?).try(&.as_s?)
end

def with_document(source : String, & : LspClient ->) : Nil
  client = LspClient.in_process
  client.initialize!("/tmp/heucristic-spec-empty")
  client.await_notification(Heucristic::Server::Notice::Indexed)
  client.open(DOCUMENT_URI, source)
  client.await_diagnostics
  yield client
  client.shutdown
end
