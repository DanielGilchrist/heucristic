class IO::FileDescriptor
  def self.set_blocking(fd : Handle, value : Bool) : Nil
  end

  def noecho(& : self -> U) : U forall U
  end
end
