class Hash(K, V)
  def self.zip(ary1 : Array(K), ary2 : Array(V)) : Hash(K, V)
  end

  def [](key) : V
  end

  def []?(key) : V?
  end

  def dig(key : K) : V
  end

  def dig?(key : K) : V?
  end

  def each : Iterator(Tuple(K, V))
  end

  def each_key : Iterator(K)
  end

  def each_key(& : K ->) : Nil
  end

  def each_value : Iterator(V)
  end

  def each_value(& : V ->) : Nil
  end

  def reject!(& : K, V -> _) : self
  end
end
