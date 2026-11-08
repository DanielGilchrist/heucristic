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

class Sync::Exclusive(T)
  def lock(& : T -> U) : U forall U
  end
end

struct Crystal::SpinLock
  def sync(& : -> U) : U forall U
  end
end
