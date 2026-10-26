module Enumerable(T)
  def chunks(&block : T -> U) : Array(Tuple(U, Array(T))) forall U
  end

  def compact_map(& : T -> U?) : Array(U) forall U
  end

  def each(& : T ->) : Nil
  end

  def each_cons(count : Int, reuse = false, & : Array(T) ->) : Nil
  end

  def each_slice(count : Int, reuse = false, & : Array(T) ->) : Nil
  end

  def each_with_index(offset = 0, & : T, typeof(offset) ->) : Nil
  end

  def find(if_none : U = nil, & : T ->) : T | U forall U
  end

  def flat_map(& : T -> Array(U) | Iterator(U) | U) : Array(U) forall U
  end

  def group_by(& : T -> U) : Hash(U, Array(T)) forall U
  end

  def in_groups_of(size : Int, filled_up_with : U = nil) : Array(Array(T | U))
  end

  def zip(*others : Indexable | Iterable | Iterator, &) : Nil
  end

  def zip?(*others : Indexable | Iterable | Iterator, &) : Nil
  end

  def reject(& : T ->) : Array(T)
  end

  def reject(type : U.class) : Array(T) forall U
  end

  def to_h(& : T -> Tuple(K, V)) : Hash(K, V) forall K, V
  end

  def reduce(& : T, T -> T) : T
  end

  def reduce(memo : U, & : U, T -> U) : U forall U
  end

  def reduce?(& : T, T -> T) : T?
  end

  def in_groups_of(size : Int, filled_up_with : U = nil, reuse = false, & : Array(T | U) ->) : Nil
  end

  def join(separator = "", & : T ->) : String
  end

  def join(io : IO, separator = "", & : T, IO ->) : Nil
  end

  def join(separator, io : IO, & : T, IO ->) : Nil
  end

  def reject(& : T ->) : Array(T)
  end

  def select(& : T ->) : Array(T)
  end

  def skip(count : Int) : Array(T)
  end

  def sum : T
  end

  def sum(& : T -> U) : U forall U
  end

  def to_h(& : T -> Tuple(K, V)) : Hash(K, V) forall K, V
  end
end
