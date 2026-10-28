module Iterable(T)
  def each_slice(count : Int, reuse = false) : Iterator(Array(T))
  end

  def each_with_index(offset = 0) : Iterator(Tuple(T, typeof(offset)))
  end
end

module Iterable(T)
  def cycle : Iterator(T)
  end

  def cycle(n) : Iterator(T)
  end
end
