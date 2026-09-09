class Object
  def try(& : self -> U) : U forall U
  end
end

struct Nil
  def try(&block : NoReturn -> U) : Nil forall U
  end
end
