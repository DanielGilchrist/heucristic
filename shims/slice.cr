struct Slice(T)
  def index(object, offset : Int = 0) : Int32?
  end
end

struct Slice(T)
  def self.new(size : Int, *, read_only = false) : Slice(T)
  end

  def self.new(size : Int, *, read_only = false, & : Int32 -> T) : Slice(T)
  end

  def self.new(size : Int, value : T, *, read_only = false) : Slice(T)
  end
end

struct Slice(T)
  def []?(range : Range) : Slice(T)?
  end
end
