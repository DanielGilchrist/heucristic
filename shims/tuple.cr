struct Tuple(*T)
  def [](index : Int) : Union(*T)
  end

  def []?(index : Int) : Union(*T)?
  end

  def <=>(other : self) : Int32
  end

  def <=>(other : Tuple) : Int32
  end

  def ==(other : self) : Bool
  end

  def ==(other : Tuple) : Bool
  end

  def ==(other) : Bool
  end

  def ===(other : self) : Bool
  end

  def ===(other : Tuple) : Bool
  end

  def at(index : Int) : Union(*T)
  end

  def clone : self
  end

  def reverse_each(& : Union(*T) ->) : Nil
  end

  def size : Int32
  end

  def to_a(& : Union(*T) -> U) : Array(U) forall U
  end

  def map(& : Union(*T) -> U) : Array(U) forall U
  end

  def unsafe_fetch(index : Int) : Union(*T)
  end
end
