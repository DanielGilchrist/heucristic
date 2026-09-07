require "../../spec_helper"

describe Heucristic::Protocol::Framing do
  it "round trips a body through a Content-Length frame" do
    io = IO::Memory.new
    Heucristic::Protocol::Framing.write(io, %({"a":1})).should be_nil
    io.rewind
    Heucristic::Protocol::Framing.read(io).should eq(%({"a":1}))
  end

  it "reports end of stream on an empty input" do
    read = Heucristic::Protocol::Framing.read(IO::Memory.new)
    read.should be_a(Heucristic::Protocol::Framing::EndOfStream)
  end

  it "reports a truncated body as end of stream" do
    io = IO::Memory.new("Content-Length: 10\r\n\r\n{}")
    Heucristic::Protocol::Framing.read(io).should be_a(Heucristic::Protocol::Framing::EndOfStream)
  end

  it "reports headers without a length as malformed" do
    io = IO::Memory.new("Content-Type: x\r\n\r\n{}")
    Heucristic::Protocol::Framing.read(io).should be_a(Heucristic::Protocol::Framing::Malformed)
  end

  it "reports an unparseable length as malformed" do
    io = IO::Memory.new("Content-Length: ten\r\n\r\n{}")
    Heucristic::Protocol::Framing.read(io).should be_a(Heucristic::Protocol::Framing::Malformed)
  end
end
