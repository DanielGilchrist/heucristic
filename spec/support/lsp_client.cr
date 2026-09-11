require "json"
require "../../src/heucristic/protocol/framing"
require "../../src/heucristic/protocol/decoder"
require "../../src/heucristic/protocol/encoder"

class LspClient
  DEFAULT_TIMEOUT = 5.seconds

  alias PositionParams = Hash(String, Hash(String, String) | Hash(String, Int32))

  getter notifications : Channel(Heucristic::Protocol::Notification)
  getter requests : Channel(Heucristic::Protocol::Request)

  def initialize(@input : IO, @output : IO) : Nil
    @next_id = 0_i64
    @responses = Channel(Heucristic::Protocol::Response).new(16)
    @notifications = Channel(Heucristic::Protocol::Notification).new(256)
    @requests = Channel(Heucristic::Protocol::Request).new(16)
    spawn { pump }
  end

  def self.in_process : LspClient
    client_reader, server_writer = IO.pipe
    server_reader, client_writer = IO.pipe
    server = Heucristic::Server::Loop.new(server_reader, server_writer)
    spawn { server.run }
    new(client_reader, client_writer)
  end

  def request(method : String, params : T) : Heucristic::Protocol::Response forall T
    id = (@next_id += 1)
    write(JSON.build do |json|
      json.object do
        json.field "jsonrpc", "2.0"
        json.field "id", id
        json.field "method", method
        json.field("params") { params.to_json(json) }
      end
    end)
    await_response(id)
  end

  def notify(method : String, params : T) : Nil forall T
    write(Heucristic::Protocol::Encoder.notification(method, params))
  end

  def initialize!(
    root : String,
    stdlib : Bool = false,
    progress : Bool = false,
    semantic : String? = nil,
  ) : Heucristic::Protocol::Response
    options = Hash(String, Bool | String).new
    options["stdlib"] = stdlib
    options["semantic"] = semantic if semantic
    response = request("initialize", {
      "processId"             => nil,
      "rootUri"               => "file://#{root}",
      "capabilities"          => {"window" => {"workDoneProgress" => progress}},
      "initializationOptions" => options,
    })
    notify("initialized", Hash(String, String).new)
    response
  end

  def open(uri : String, text : String, version : Int32 = 1) : Nil
    notify("textDocument/didOpen", {
      "textDocument" => {
        "uri" => uri, "languageId" => "crystal", "version" => version, "text" => text,
      },
    })
  end

  def change(uri : String, version : Int32, changes : Array(T)) : Nil forall T
    notify("textDocument/didChange", {
      "textDocument"   => {"uri" => uri, "version" => version},
      "contentChanges" => changes,
    })
  end

  def hover(uri : String, line : Int32, character : Int32) : Heucristic::Protocol::Response
    request("textDocument/hover", position_params(uri, line, character))
  end

  def definition(uri : String, line : Int32, character : Int32) : Heucristic::Protocol::Response
    request("textDocument/definition", position_params(uri, line, character))
  end

  def shutdown : Nil
    request("shutdown", nil)
    notify("exit", nil)
  end

  def await_notification(
    method : String,
    timeout : Time::Span = DEFAULT_TIMEOUT,
  ) : Heucristic::Protocol::Notification
    deadline = Time.instant + timeout
    loop do
      remaining = deadline - Time.instant
      raise "timed out waiting for #{method}" if remaining <= Time::Span.zero

      select
      when notification = @notifications.receive
        return notification if notification.method == method
      when timeout(remaining)
        raise "timed out waiting for #{method}"
      end
    end
  end

  private def position_params(uri : String, line : Int32, character : Int32) : PositionParams
    {"textDocument" => {"uri" => uri}, "position" => {"line" => line, "character" => character}}
  end

  private def await_response(id : Int64) : Heucristic::Protocol::Response
    select
    when response = @responses.receive
      raise "response id mismatch: wanted #{id}, got #{response.id}" unless response.id == id
      response
    when timeout(DEFAULT_TIMEOUT)
      raise "timed out waiting for response #{id}"
    end
  end

  private def write(body : String) : Nil
    written = Heucristic::Protocol::Framing.write(@output, body)
    raise written.reason if written.is_a?(Heucristic::Protocol::Framing::Disconnected)
  end

  private def pump : Nil
    loop do
      frame = Heucristic::Protocol::Framing.read(@input)
      break unless frame.is_a?(String)

      case (message = Heucristic::Protocol::Decoder.decode(frame))
      in Heucristic::Protocol::Response     then @responses.send(message)
      in Heucristic::Protocol::Notification then @notifications.send(message)
      in Heucristic::Protocol::Request      then @requests.send(message)
      in Heucristic::Protocol::Unparseable
        raise "server sent unparseable message: #{message.reason}"
      end
    end
  end
end
