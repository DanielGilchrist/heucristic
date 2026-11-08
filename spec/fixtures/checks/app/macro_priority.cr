class Keyed
  macro key(name)
  end

  def self.key : String
    "k"
  end
end

class Stamped < Keyed
  key :user
end

Greeter.new.gret("a")
