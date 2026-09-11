class File
  def self.open(filename : Path | String, mode = "r", perm = DEFAULT_CREATE_PERMISSIONS, encoding = nil, invalid = nil, blocking = nil, & : File -> U) : U forall U
  end

  def self.write(filename : Path | String, content, perm = DEFAULT_CREATE_PERMISSIONS, encoding = nil, invalid = nil, mode = "w", blocking = nil) : Nil
  end
end
