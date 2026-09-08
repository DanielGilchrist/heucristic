module Iterator(T)
  def self.empty : Iterator(T)
  end

  def self.of(element : T) : Iterator(T)
  end

  def self.of(&block : -> T) : Iterator(T)
  end

  def self.stop : Iterator::Stop
  end

  def accumulate : Iterator(T)
  end

  def accumulate(&block : T, T -> T) : Iterator(T)
  end

  def accumulate(initial : U) : Iterator(U)
  end

  def accumulate(initial : U, &block : U, T -> U) : Iterator(U)
  end

  def chain(other : Iterator(U)) : Iterator(T | U)
  end

  def chunk(reuse = false, &block : T -> U) : Iterator(Tuple(U, Array(T)))
  end

  def chunk_while(reuse : Bool | Array(T) = false, &block : T, T -> B) : Iterator(Array(T))
  end

  def compact_map(&func : T -> U?) : Iterator(U) forall U
  end

  def cons(n : Int, reuse = false) : Iterator(Array(T))
  end

  def cycle : Iterator(T)
  end

  def cycle(n : Int) : Iterator(T)
  end

  def each : self
  end

  def each_slice(n, reuse = false) : Iterator(Array(T))
  end

  def first(n : Int) : Iterator(T)
  end

  def flat_map(&func : T -> Array(U) | Iterator(U) | U) : Iterator(U) forall U
  end

  def map(&func : T -> U) : Iterator(U)
  end

  def next : T | Iterator::Stop
  end

  def reject(&func : T -> U) : Iterator(T)
  end

  def reject(pattern) : Iterator(T)
  end

  def select(&func : T -> U) : Iterator(T)
  end

  def select(pattern) : Iterator(T)
  end

  def select(type : U.class) : Iterator(U)
  end

  def skip(n : Int) : Iterator(T)
  end

  def skip_while(&func : T -> U) : Iterator(T)
  end

  def slice(n : Int, reuse = false) : Iterator(Array(T))
  end

  def slice_after(pattern, reuse : Bool | Array(T) = false) : Iterator(Array(T))
  end

  def slice_after(reuse : Bool | Array(T) = false, &block : T -> B) : Iterator(Array(T))
  end

  def slice_before(pattern, reuse : Bool | Array(T) = false) : Iterator(Array(T))
  end

  def slice_before(reuse : Bool | Array(T) = false, &block : T -> B) : Iterator(Array(T))
  end

  def slice_when(reuse : Bool | Array(T) = false, &block : T, T -> B) : Iterator(Array(T))
  end

  def step(n : Int) : Iterator(T)
  end

  def stop : Iterator::Stop
  end

  def take_while(&func : T -> U) : Iterator(T)
  end

  def tap(&block : T ->) : Iterator(T)
  end

  def uniq : Iterator(T)
  end

  def uniq(&func : T -> U) : Iterator(T)
  end

  def with_index(offset : Int = 0) : Iterator(Tuple(T, Int32))
  end

  def with_index(offset : Int = 0, & : T, Int32 ->) : Nil
  end
end
