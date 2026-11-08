struct StaticArray(T, N)
  def self.new(& : Int32 -> T) : self
  end

  def self.new(value : T) : self
  end
end
