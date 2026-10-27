class Array(T)
  def self.new(size : Int, & : Int32 -> T) : Array(T)
  end

  def []=(range : Range, value : T) : T
  end

  def []=(range : Range, values : Array(T)) : Array(T)
  end

  def []=(start : Int, count : Int, values : Array(T)) : Array(T)
  end

  def []=(value : T, *, index start : Int, count : Int) : T
  end

  def []=(values : Array(T), *, index start : Int, count : Int) : Array(T)
  end

  def <=>(other : Array) : Int32
  end

  def index(object, offset : Int = 0) : Int32?
  end

  def map_with_index(offset = 0, & : T, Int32 -> U) : Array(U) forall U
  end

  def product(ary : Array(U)) : Array(Tuple(T, U)) forall U
  end

  def to_lookup_hash(& : T -> U) : Hash(U, T) forall U
  end

  def to_unsafe_slice : Slice(T)
  end

  def to_unsafe_slice(start : Int, count : Int) : Slice(T)
  end
end
