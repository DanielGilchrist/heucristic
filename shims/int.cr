struct Int
  def ~ : self
  end

  def ===(char : Char) : Bool
  end
end

struct Int
  def times : Iterator(self)
  end
end

struct Int
  def //(other : Int::Primitive) : self
  end

  def %(other : Int) : self
  end

  def >>(count : Int) : self
  end

  def <<(count : Int) : self
  end
end
