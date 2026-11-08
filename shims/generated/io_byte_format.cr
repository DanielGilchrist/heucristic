module IO::ByteFormat::LittleEndian
  def self.encode(int : Int8, io : IO) : Nil
  end

  def self.encode(int : Int8, bytes : Bytes) : Nil
  end

  def self.decode(int : Int8.class, io : IO) : Int8
  end

  def self.decode(int : Int8.class, bytes : Bytes) : Int8
  end

  def self.encode(int : UInt8, io : IO) : Nil
  end

  def self.encode(int : UInt8, bytes : Bytes) : Nil
  end

  def self.decode(int : UInt8.class, io : IO) : UInt8
  end

  def self.decode(int : UInt8.class, bytes : Bytes) : UInt8
  end

  def self.encode(int : Int16, io : IO) : Nil
  end

  def self.encode(int : Int16, bytes : Bytes) : Nil
  end

  def self.decode(int : Int16.class, io : IO) : Int16
  end

  def self.decode(int : Int16.class, bytes : Bytes) : Int16
  end

  def self.encode(int : UInt16, io : IO) : Nil
  end

  def self.encode(int : UInt16, bytes : Bytes) : Nil
  end

  def self.decode(int : UInt16.class, io : IO) : UInt16
  end

  def self.decode(int : UInt16.class, bytes : Bytes) : UInt16
  end

  def self.encode(int : Int32, io : IO) : Nil
  end

  def self.encode(int : Int32, bytes : Bytes) : Nil
  end

  def self.decode(int : Int32.class, io : IO) : Int32
  end

  def self.decode(int : Int32.class, bytes : Bytes) : Int32
  end

  def self.encode(int : UInt32, io : IO) : Nil
  end

  def self.encode(int : UInt32, bytes : Bytes) : Nil
  end

  def self.decode(int : UInt32.class, io : IO) : UInt32
  end

  def self.decode(int : UInt32.class, bytes : Bytes) : UInt32
  end

  def self.encode(int : Int64, io : IO) : Nil
  end

  def self.encode(int : Int64, bytes : Bytes) : Nil
  end

  def self.decode(int : Int64.class, io : IO) : Int64
  end

  def self.decode(int : Int64.class, bytes : Bytes) : Int64
  end

  def self.encode(int : UInt64, io : IO) : Nil
  end

  def self.encode(int : UInt64, bytes : Bytes) : Nil
  end

  def self.decode(int : UInt64.class, io : IO) : UInt64
  end

  def self.decode(int : UInt64.class, bytes : Bytes) : UInt64
  end

  def self.encode(int : Int128, io : IO) : Nil
  end

  def self.encode(int : Int128, bytes : Bytes) : Nil
  end

  def self.decode(int : Int128.class, io : IO) : Int128
  end

  def self.decode(int : Int128.class, bytes : Bytes) : Int128
  end

  def self.encode(int : UInt128, io : IO) : Nil
  end

  def self.encode(int : UInt128, bytes : Bytes) : Nil
  end

  def self.decode(int : UInt128.class, io : IO) : UInt128
  end

  def self.decode(int : UInt128.class, bytes : Bytes) : UInt128
  end
end

module IO::ByteFormat::BigEndian
  def self.encode(int : Int8, io : IO) : Nil
  end

  def self.encode(int : Int8, bytes : Bytes) : Nil
  end

  def self.decode(int : Int8.class, io : IO) : Int8
  end

  def self.decode(int : Int8.class, bytes : Bytes) : Int8
  end

  def self.encode(int : UInt8, io : IO) : Nil
  end

  def self.encode(int : UInt8, bytes : Bytes) : Nil
  end

  def self.decode(int : UInt8.class, io : IO) : UInt8
  end

  def self.decode(int : UInt8.class, bytes : Bytes) : UInt8
  end

  def self.encode(int : Int16, io : IO) : Nil
  end

  def self.encode(int : Int16, bytes : Bytes) : Nil
  end

  def self.decode(int : Int16.class, io : IO) : Int16
  end

  def self.decode(int : Int16.class, bytes : Bytes) : Int16
  end

  def self.encode(int : UInt16, io : IO) : Nil
  end

  def self.encode(int : UInt16, bytes : Bytes) : Nil
  end

  def self.decode(int : UInt16.class, io : IO) : UInt16
  end

  def self.decode(int : UInt16.class, bytes : Bytes) : UInt16
  end

  def self.encode(int : Int32, io : IO) : Nil
  end

  def self.encode(int : Int32, bytes : Bytes) : Nil
  end

  def self.decode(int : Int32.class, io : IO) : Int32
  end

  def self.decode(int : Int32.class, bytes : Bytes) : Int32
  end

  def self.encode(int : UInt32, io : IO) : Nil
  end

  def self.encode(int : UInt32, bytes : Bytes) : Nil
  end

  def self.decode(int : UInt32.class, io : IO) : UInt32
  end

  def self.decode(int : UInt32.class, bytes : Bytes) : UInt32
  end

  def self.encode(int : Int64, io : IO) : Nil
  end

  def self.encode(int : Int64, bytes : Bytes) : Nil
  end

  def self.decode(int : Int64.class, io : IO) : Int64
  end

  def self.decode(int : Int64.class, bytes : Bytes) : Int64
  end

  def self.encode(int : UInt64, io : IO) : Nil
  end

  def self.encode(int : UInt64, bytes : Bytes) : Nil
  end

  def self.decode(int : UInt64.class, io : IO) : UInt64
  end

  def self.decode(int : UInt64.class, bytes : Bytes) : UInt64
  end

  def self.encode(int : Int128, io : IO) : Nil
  end

  def self.encode(int : Int128, bytes : Bytes) : Nil
  end

  def self.decode(int : Int128.class, io : IO) : Int128
  end

  def self.decode(int : Int128.class, bytes : Bytes) : Int128
  end

  def self.encode(int : UInt128, io : IO) : Nil
  end

  def self.encode(int : UInt128, bytes : Bytes) : Nil
  end

  def self.decode(int : UInt128.class, io : IO) : UInt128
  end

  def self.decode(int : UInt128.class, bytes : Bytes) : UInt128
  end
end
