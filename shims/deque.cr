class Deque(T)
  def push(value : T) : self
  end

  def <<(value : T) : self
  end

  def shift? : T?
  end
end

class Deque(T)
  def clear : self
  end

  def shift : T
  end

  def shift(& : -> U) : T | U forall U
  end
end
