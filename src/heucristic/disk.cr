module Heucristic
  module Disk
    extend self

    record Unreadable, path : String, reason : String
    record Unwritable, path : String, reason : String

    def read(path : String) : String | Unreadable
      File.read(path)
    rescue error : IO::Error
      Unreadable.new(path, error.message || error.class.name)
    end

    def write(path : String, contents : String) : Unwritable?
      Dir.mkdir_p(File.dirname(path))
      File.write(path, contents)
      nil
    rescue error : IO::Error
      Unwritable.new(path, error.message || error.class.name)
    end
  end
end
