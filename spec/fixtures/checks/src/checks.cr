class Greeter
  def greet(name : String) : String
    name
  end

  def shout(name : String, times : Int32) : String
    name * times
  end

  def config(a : Int32, *, key : String) : Nil
  end

  private def secret : Nil
  end

  protected def guarded : Nil
  end

  def each_twice(& : -> Nil) : Nil
    yield
    yield
  end
end

record Point, x : Int32, y : Int32

macro twice(text)
  puts {{ text }}
  puts {{ text }}
end

enum Clock
  Start
  Finish
  BreakStart
end

abstract class Shape
  abstract def area : Int32
end

class Sizes
  def fine(flag : Bool) : Int32?
    flag ? 1 : nil
  end
end

class Square < Shape
  def area : Int32
    4
  end
end
