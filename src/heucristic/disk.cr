require "file_utils"

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

    def rename(from : String, to : String) : Unwritable?
      File.rename(from, to)
      nil
    rescue error : File::Error
      return if Dir.exists?(to)

      Unwritable.new(to, error.message || error.class.name)
    end

    def remove_tree(path : String) : Unwritable?
      FileUtils.rm_rf(path)
      nil
    rescue error : File::Error
      Unwritable.new(path, error.message || error.class.name)
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
