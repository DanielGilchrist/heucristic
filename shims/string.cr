class String
  def split(limit : Int32? = nil, &block : String -> U) : U? forall U
  end

  def split(separator : Char, limit = nil, *, remove_empty = false, &block : String -> U) : U? forall U
  end

  def split(separator : String, limit = nil, *, remove_empty = false, &block : String -> U) : U? forall U
  end

  def rindex(search : Char, offset = size - 1) : Int32?
  end

  def self.build(capacity = 64, & : String::Builder ->) : self
  end

  def to_i(base : Int = 10, whitespace : Bool = true, underscore : Bool = false, prefix : Bool = false, strict : Bool = true, leading_zero_is_octal : Bool = false) : Int32
  end

  def each_byte(& : UInt8 ->) : Nil
  end

  def each_byte : Iterator(UInt8)
  end

  def to_i?(base : Int = 10, whitespace : Bool = true, underscore : Bool = false, prefix : Bool = false, strict : Bool = true, leading_zero_is_octal : Bool = false) : Int32?
  end
end

class String
  def index(search : String, offset = 0) : Int32?
  end

  def each_line(chomp = true, *, remove_empty : Bool = false) : Iterator(String)
  end

  def each_char : Iterator(Char)
  end
end
