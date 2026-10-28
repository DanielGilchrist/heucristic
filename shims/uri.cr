struct URI::Params
  def []=(name, value : String | Array(String)) : Array(String)
  end

  def to_s(*, space_to_plus : Bool = true) : String
  end
end

class URI::Params::Builder
  def add(key, value : String?) : self
  end

  def add(key, values : Array) : self
  end
end
