class IO
  def flush : Nil
  end

  def read_bytes(type : T.class, format : IO::ByteFormat = IO::ByteFormat::SystemEndian) : T forall T
  end
end
