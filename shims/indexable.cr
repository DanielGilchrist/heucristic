module Indexable(T)
  def [](index : Int) : T
  end

  def []?(index : Int) : T?
  end

  def bsearch(& : T -> _) : T?
  end

  def bsearch_index(& : T, Int32 -> _) : Int32?
  end

  def combinations(size : Int = self.size) : Array(Array(T))
  end

  def dig(index : Int) : T
  end

  def dig?(index : Int) : T?
  end

  def each : Iterator(T)
  end

  def each(& : T ->) : Nil
  end

  def each(*, start : Int, count : Int, & : T ->) : self
  end

  def each(*, within range : Range, & : T ->) : self
  end

  def each_combination(size : Int = self.size, reuse = false) : Iterator(Array(T))
  end

  def each_index : Iterator(Int32)
  end

  def each_index(*, start : Int, count : Int, & : Int32 ->) : self
  end

  def each_permutation(size : Int = self.size, reuse = false) : Iterator(Array(T))
  end

  def each_repeated_combination(size : Int = self.size, reuse = false) : Iterator(Array(T))
  end

  def find!(offset : Int = 0, & : T ->) : T
  end

  def index(object, offset : Int = 0) : Int32?
  end

  def index(offset : Int = 0, & : T ->) : Int32?
  end

  def index!(obj, offset : Int = 0) : Int32
  end

  def index!(offset : Int = 0, & : T ->) : Int32
  end

  def reverse_each : Iterator(T)
  end

  def rindex(value, offset = size - 1) : Int32?
  end

  def rindex(offset = size - 1, & : T ->) : Int32?
  end

  def rindex!(value, offset = size - 1) : Int32
  end

  def rindex!(offset = size - 1, & : T ->) : Int32
  end

  def sample(random : Random? = nil) : T
  end

  def size : Int32
  end

  def unsafe_fetch(index : Int) : T
  end
end
