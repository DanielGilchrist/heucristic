class Object
  def try(& : self -> U) : U forall U
  end
end

struct Nil
  def try(&block : NoReturn -> U) : Nil forall U
  end
end

class Object
  def tap(& : self ->) : self
  end

  def ==(other) : Bool
  end

  def !=(other) : Bool
  end

  def ===(other) : Bool
  end
end

struct Value
  def ==(other) : Bool
  end
end

class Reference
  def ==(other : self) : Bool
  end

  def ==(other) : Bool
  end
end

struct Nil
  def ==(other : Nil) : Bool
  end
end

class Object
  def not_nil! : self
  end

  def not_nil!(message) : self
  end

  def itself : self
  end
end
