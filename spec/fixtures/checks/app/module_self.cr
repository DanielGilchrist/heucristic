module Guarded
  def guard : Nil
    Registry.accept(self)
  end
end

class Action
end

class Handler < Action
  include Guarded
end

module Registry
  def self.accept(action : Action) : Nil
  end
end

Greeter.new.gret("a")
