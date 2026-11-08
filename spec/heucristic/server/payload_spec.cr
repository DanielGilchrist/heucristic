require "../../spec_helper"

private alias Server = Heucristic::Server

describe "notification payloads" do
  it "serializes a pending main macro status with its nulls" do
    Server::MacrosPending.new.payload.to_json.should eq(
      {status: "pending", defs: 0, elapsed_ms: 0.0, reason: nil, target: "main"}.to_json
    )
  end

  it "serializes a done main macro status with its exclusion note" do
    payload = Server::MacrosDone.new(12, 840.0, "left out a.cr").payload

    payload.to_json.should eq(
      {status: "done", defs: 12, elapsed_ms: 840.0, reason: "left out a.cr", target: "main"}.to_json
    )
  end

  it "serializes a done main macro status without a note" do
    Server::MacrosDone.new(3, 1.0, nil).payload.to_json.should eq(
      {status: "done", defs: 3, elapsed_ms: 1.0, reason: nil, target: "main"}.to_json
    )
  end

  it "serializes stale and unavailable main macro statuses" do
    Server::MacrosStale.new("boom", 7).payload.to_json.should eq(
      {status: "stale", defs: 7, elapsed_ms: 0.0, reason: "boom", target: "main"}.to_json
    )
    Server::MacrosOff.new("no helper").payload.to_json.should eq(
      {status: "unavailable", defs: 0, elapsed_ms: 0.0, reason: "no helper", target: "main"}.to_json
    )
  end

  it "serializes a payload for a spec or loose target" do
    payload = Server::MacrosPayload.new(:stale, 4, 0.0, "boom", :loose)

    payload.to_json.should eq(
      {status: "stale", defs: 4, elapsed_ms: 0.0, reason: "boom", target: "loose"}.to_json
    )
  end

  it "serializes compiler statuses" do
    Server::CompilerPending.new.payload.to_json.should eq(
      {
        status: "pending", errors: 0, elapsed_ms: 0.0, reason: nil,
        file: nil, line: nil, message: nil,
      }.to_json
    )
    Server::CompilerDone.new(1, 2210.0, "/p/src/a.cr", 3, "boom").payload.to_json.should eq(
      {
        status: "done", errors: 1, elapsed_ms: 2210.0, reason: nil,
        file: "/p/src/a.cr", line: 3, message: "boom",
      }.to_json
    )
    Server::CompilerBroken.new("crashed").payload.to_json.should eq(
      {
        status: "failed", errors: 0, elapsed_ms: 0.0, reason: "crashed",
        file: nil, line: nil, message: nil,
      }.to_json
    )
    Server::CompilerOff.new("no crystal").payload.to_json.should eq(
      {
        status: "unavailable", errors: 0, elapsed_ms: 0.0, reason: "no crystal",
        file: nil, line: nil, message: nil,
      }.to_json
    )
  end

  it "serializes the indexed notice" do
    Server::IndexedPayload.new(2420, 14, 570.0).to_json.should eq(
      {files: 2420, shims: 14, elapsed_ms: 570.0}.to_json
    )
  end
end
