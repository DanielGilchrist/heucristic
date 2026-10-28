struct NamedTuple
  def merge(other : NamedTuple) : NamedTuple
  end

  def merge(**other : **U) : NamedTuple forall U
  end

  def keys : Tuple
  end

  def values : Tuple
  end

  def each_with_index(offset = 0, &) : Nil
  end

  def empty? : Bool
  end
end
