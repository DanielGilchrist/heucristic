module Heucristic
  module Disk
    extend self

    record Unreadable, path : String, reason : String

    def read(path : String) : String | Unreadable
      File.read(path)
    rescue error : IO::Error
      Unreadable.new(path, error.message || error.class.name)
    end
  end
end
