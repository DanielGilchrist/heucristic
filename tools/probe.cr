require "json"
require "../spec/support/lsp_client"
require "./probe/invocation"
require "./probe/root"

module Probe
  extend self

  def run(args : Array(String)) : Int32
    invocation = Invocation.parse(args)
    return invocation.report if invocation.is_a?(Invalid)

    file = invocation.file
    directory = File.dirname(file)
    lookup = Roots.find(directory)
    root = case lookup
           in Root   then lookup.path
           in NoRoot then directory
           end
    uri = "file://#{file}"

    process = Process.new(invocation.binary, input: :pipe, output: :pipe, error: :inherit)
    client = LspClient.new(process.output, process.input)

    client.initialize!(root, stdlib: true, progress: true)
    indexed = await_indexed(client)
    STDERR.puts "indexed: #{indexed.params}"
    macros = await_macros(client)
    STDERR.puts "macros: #{macros.params}"

    client.open(uri, File.read(file))
    diagnostics = client.await_diagnostics
    puts "diagnostics: #{diagnostics.params.try(&.["diagnostics"]).to_pretty_json}"

    query(client, uri, invocation)

    client.shutdown
    process.wait.exit_code
  end

  private def query(client : LspClient, uri : String, invocation : Invocation) : Nil
    line = invocation.line
    character = invocation.character
    action = invocation.action
    case action
    in Hover      then print_hover(client, uri, line, character)
    in Definition then print_definition(client, uri, line, character)
    in Both
      print_hover(client, uri, line, character)
      print_definition(client, uri, line, character)
    in References
      found = client.references(uri, line, character, true).result
      puts "references: #{found.to_pretty_json}"
    in Complete
      puts "completion: #{client.completion(uri, line, character).result.to_pretty_json}"
    in Rename
      edit = client.rename(uri, line, character, action.name)
      puts "rename: #{(edit.result || edit.error).to_pretty_json}"
    in Symbols
      puts "symbols: #{client.document_symbols(uri).result.to_pretty_json}"
    in Workspace
      puts "workspace symbols: #{client.workspace_symbols(action.query).result.to_pretty_json}"
    end
  end

  private def print_hover(client : LspClient, uri : String, line : Int32, character : Int32) : Nil
    puts "hover: #{client.hover(uri, line, character).result.to_pretty_json}"
  end

  private def print_definition(
    client : LspClient,
    uri : String,
    line : Int32,
    character : Int32,
  ) : Nil
    puts "definition: #{client.definition(uri, line, character).result.to_pretty_json}"
  end

  private def await_macros(client : LspClient) : Heucristic::Protocol::Notification
    loop do
      notice = Heucristic::Server::Notice::Macros
      notification = client.await_notification(notice, 60.seconds)
      stage = Heucristic::Server::Stage.read(notification.params)
      return notification unless stage == Heucristic::Server::Stage::Pending
    end
  end

  private def await_indexed(client : LspClient) : Heucristic::Protocol::Notification
    loop do
      notification = client.await_notification(:progress, 30.seconds)
      STDERR.puts "progress: #{notification.params.try(&.["value"]?)}"
      break if notification.params.try(&.["value"]?.try(&.["kind"]?)) == "end"
    end
    client.await_notification(Heucristic::Server::Notice::Indexed, 30.seconds)
  end
end

exit Probe.run(ARGV)
