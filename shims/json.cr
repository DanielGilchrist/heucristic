module JSON
  def self.build(indent : String | Int | Nil = nil, & : JSON::Builder ->) : String
  end

  def self.build(io : IO, indent : String | Int | Nil = nil, & : JSON::Builder ->) : Nil
  end
end

class JSON::Builder
  def object(& : -> U) : U forall U
  end

  def field(name, & : -> U) : U forall U
  end
end
