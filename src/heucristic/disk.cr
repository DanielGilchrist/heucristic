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

    def children(path : String) : Array(String) | Unreadable
      Dir.children(path)
    rescue error : File::Error
      Unreadable.new(path, error.message || error.class.name)
    end

    def modified_at(path : String) : Time | Unreadable
      File.info(path).modification_time
    rescue error : File::Error
      Unreadable.new(path, error.message || error.class.name)
    end

    def touch(path : String) : Unwritable?
      File.touch(path)
      nil
    rescue error : File::Error
      Unwritable.new(path, error.message || error.class.name)
    end

    def make_tree(path : String, attempts : Int32 = 3) : Unwritable?
      Dir.mkdir_p(path)
      nil
    rescue error : File::Error
      return if Dir.exists?(path)
      return make_tree(path, attempts - 1) if attempts > 1

      Unwritable.new(path, error.message || error.class.name)
    end

    def write(path : String, contents : String) : Unwritable?
      made = make_tree(File.dirname(path))
      return made if made

      File.write(path, contents)
      nil
    rescue error : IO::Error
      Unwritable.new(path, error.message || error.class.name)
    end
  end
end
