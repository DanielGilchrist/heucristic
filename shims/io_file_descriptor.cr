class IO::FileDescriptor
  def noecho(& : self -> U) : U forall U
  end
end

class IO::FileDescriptor
  def self.new(fd : Handle, blocking = nil, close_on_finalize = true) : self
  end
end

class IO::FileDescriptor
  def self.set_blocking(fd : Handle, value : Bool) : Int32?
  end
end
