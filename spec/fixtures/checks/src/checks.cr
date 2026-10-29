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

  def optional : String?
    nil
  end

  def configure_with(& : ->) : Nil
    with self yield
  end

  def each_twice(& : -> Nil) : Nil
    yield
    yield
  end
end

record Point, x : Int32, y : Int32

macro wrap(&block)
  {{ block.body }}
end

macro pick(&block)
  {{ block.body.expressions[0] }}
end

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

class Builder
  def add(item : String) : Nil
  end
end

def build(& : ->) : Nil
  builder = Builder.new
  with builder yield
end

module Shop
  enum BarColor
    Red
    Green
  end
end

enum Color
  Red
end

private enum Mood
  Up
  Down
end

def moody : Int32
  case Mood::Up
  in Mood::Up then 1
  end
end
