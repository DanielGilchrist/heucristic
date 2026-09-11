require "json"
require "../spec/support/lsp_client"

module Probe
  extend self

  def run(args : Array(String)) : Int32
    binary, file, line, character, action = parse(args) || return usage
    root = find_root(File.dirname(file))
    uri = "file://#{file}"

    process = Process.new(binary, input: :pipe, output: :pipe, error: :inherit)
    client = LspClient.new(process.output, process.input)

    client.initialize!(root, stdlib: true, progress: true)
    indexed = await_indexed(client)
    STDERR.puts "indexed: #{indexed.params}"
    macros = await_macros(client)
    STDERR.puts "macros: #{macros.try(&.params)}"

    client.open(uri, File.read(file))
    diagnostics = client.await_notification("textDocument/publishDiagnostics")
    puts "diagnostics: #{diagnostics.params.try(&.["diagnostics"]).to_pretty_json}"

    if action.in?("hover", "both")
      puts "hover: #{client.hover(uri, line, character).result.to_pretty_json}"
    end
    if action.in?("definition", "both")
      puts "definition: #{client.definition(uri, line, character).result.to_pretty_json}"
    end

    client.shutdown
    process.wait.exit_code
  end

  private def await_macros(client : LspClient) : Heucristic::Protocol::Notification?
    loop do
      notification = client.await_notification("$/heucristic/macros", 60.seconds) rescue return
      return notification unless notification.params.try(&.["status"]?) == "pending"
    end
  end

  private def await_indexed(client : LspClient) : Heucristic::Protocol::Notification
    loop do
      notification = client.await_notification("$/progress", 30.seconds) rescue break
      STDERR.puts "progress: #{notification.params.try(&.["value"]?)}"
      break if notification.params.try(&.["value"]?.try(&.["kind"]?)) == "end"
    end
    client.await_notification("$/heucristic/indexed", 30.seconds)
  end

  private def parse(args : Array(String)) : {String, String, Int32, Int32, String}?
    return unless args.size >= 2

    binary = ENV.fetch("HEUCRISTIC_BIN", File.join(Dir.current, "bin", "heucristic"))
    file = File.expand_path(args[0])
    position = args[1].split(':')
    return unless position.size == 2

    line = position[0].to_i32?
    character = position[1].to_i32?
    return unless line && character

    {binary, file, line - 1, character - 1, args[2]? || "both"}
  end

  private def find_root(directory : String) : String
    current = directory
    until File.exists?(File.join(current, "shard.yml")) || current == "/"
      current = File.dirname(current)
    end
    current == "/" ? directory : current
  end

  private def usage : Int32
    STDERR.puts "usage: probe <file.cr> <line>:<column> [hover|definition|both]"
    STDERR.puts "positions are 1-based; HEUCRISTIC_BIN overrides the server binary"
    1
  end
end

exit Probe.run(ARGV)
