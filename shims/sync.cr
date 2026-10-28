class Sync::Mutex
  def synchronize(& : -> U) : U forall U
  end
end

class Sync::Shared(T)
  def shared(& : T -> U) : U forall U
  end

  def lock(& : T -> U) : U forall U
  end
end
