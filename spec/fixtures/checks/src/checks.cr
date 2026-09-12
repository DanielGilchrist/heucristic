class Greeter
  def greet(name : String) : String
    name
  end

  def each_twice(& : -> Nil) : Nil
    yield
    yield
  end
end

record Point, x : Int32, y : Int32
