class File
  def self.open(filename : Path | String, mode = "r", perm = DEFAULT_CREATE_PERMISSIONS, encoding = nil, invalid = nil, blocking = nil, & : File -> U) : U forall U
  end

  def self.write(filename : Path | String, content, perm = DEFAULT_CREATE_PERMISSIONS, encoding = nil, invalid = nil, mode = "w", blocking = nil) : Nil
  end
end

class File
  def self.tempfile(prefix : String?, suffix : String?, *, dir : String = Dir.tempdir, encoding = nil, invalid = nil) : File
  end

  def self.tempfile(suffix : String? = nil, *, dir : String = Dir.tempdir, encoding = nil, invalid = nil) : File
  end

  def self.tempfile(prefix : String?, suffix : String?, *, dir : String = Dir.tempdir, encoding = nil, invalid = nil, & : File ->) : File
  end

  def self.tempfile(suffix : String? = nil, *, dir : String = Dir.tempdir, encoding = nil, invalid = nil, & : File ->) : File
  end
end

class File
  def self.new(filename : Path | String, mode = "r", perm = DEFAULT_CREATE_PERMISSIONS, encoding = nil, invalid = nil, blocking = nil) : self
  end
end
