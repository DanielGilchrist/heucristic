abstract struct Enum
  def ==(other) : Bool
  end

  def ==(other : self) : Bool
  end
end

abstract struct Enum
  def self.each(& : self -> U) : U? forall U
  end

  def self.new(value : self) : self
  end
end
