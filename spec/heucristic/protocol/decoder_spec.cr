require "../../spec_helper"

describe Heucristic::Protocol::Decoder do
  it "decodes a request" do
    body = %({"jsonrpc":"2.0","id":1,"method":"m","params":{"x":1}})
    message = Heucristic::Protocol::Decoder.decode(body)
    message.should be_a(Heucristic::Protocol::Request)
    message.as?(Heucristic::Protocol::Request).try(&.id).should eq(1)
  end

  it "decodes a string id" do
    body = %({"jsonrpc":"2.0","id":"abc","method":"m"})
    message = Heucristic::Protocol::Decoder.decode(body)
    message.as?(Heucristic::Protocol::Request).try(&.id).should eq("abc")
  end

  it "decodes a notification" do
    message = Heucristic::Protocol::Decoder.decode(%({"jsonrpc":"2.0","method":"m"}))
    message.should be_a(Heucristic::Protocol::Notification)
  end

  it "decodes a response" do
    message = Heucristic::Protocol::Decoder.decode(%({"jsonrpc":"2.0","id":2,"result":null}))
    message.should be_a(Heucristic::Protocol::Response)
  end

  it "reports invalid json" do
    Heucristic::Protocol::Decoder.decode("{").should be_a(Heucristic::Protocol::Unparseable)
  end

  it "reports a non object" do
    Heucristic::Protocol::Decoder.decode("[]").should be_a(Heucristic::Protocol::Unparseable)
  end

  it "reports an id of the wrong type" do
    message = Heucristic::Protocol::Decoder.decode(%({"id":1.5,"method":"m"}))
    message.should be_a(Heucristic::Protocol::Unparseable)
  end
end
