module Comparable(T)
  def ==(other : T) : Bool
  end

  def <=(other : T) : Bool
  end

  def >=(other : T) : Bool
  end

  def clamp(range : Range) : self
  end

  def clamp(min, max) : self
  end
end
