struct Set(T)
  def self.new(other : Indexable(T)) : self
  end

  def self.new(enumerable : Enumerable(T)) : self
  end
end
