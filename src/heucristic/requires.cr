module Heucristic
  struct Requires
    record Unresolved, tried : Array(String)

    def initialize(@source_paths : Array(String)) : Nil
    end

    def resolve(string : String, relative_to : String) : Array(String) | Unresolved
      tried = Array(String).new
      directory = File.dirname(relative_to)
      if string.starts_with?('.')
        found = within(string, directory, tried)
        return found if found
      else
        @source_paths.each do |entry|
          found = within(string, entry, tried)
          return found if found
        end
      end
      Unresolved.new(tried)
    end

    private def within(string : String, directory : String, tried : Array(String)) : Array(String)?
      globbing = string.ends_with?("/*") || string.ends_with?("/**")
      return globbed(string, directory, tried) if globbing

      each_expansion(string, directory) do |candidate|
        absolute = File.expand_path(candidate)
        return [absolute] if File.file?(absolute)

        tried << absolute
      end
      nil
    end

    private def globbed(string : String, directory : String, tried : Array(String)) : Array(String)?
      recursive = string.ends_with?("/**")
      parent = File.expand_path(string[0...string.rindex!('/')], directory)
      unless Dir.exists?(parent)
        tried << parent
        return
      end

      files = Array(String).new
      gather(parent, files, recursive)
      files
    end

    private def gather(directory : String, files : Array(String), recursive : Bool) : Nil
      children = Array(String).new
      directories = Array(String).new
      Dir.each_child(directory) do |name|
        full = File.join(directory, name)
        if File.directory?(full)
          directories << full if recursive
        elsif name.ends_with?(".cr")
          children << full
        end
      end
      files.concat(children.sort!)
      directories.sort!.each { |child| gather(child, files, recursive) }
    end

    private def each_expansion(string : String, directory : String, & : String ->) : Nil
      joined = File.join(directory, string)
      yield joined.ends_with?(".cr") ? joined : "#{joined}.cr"

      relative = string.starts_with?('.')
      shard_name, _, shard_path = string.partition('/')
      basename = File.basename(joined, ".cr")

      if !relative && !shard_path.empty?
        shard_src = File.join(directory, shard_name, "src")
        stem = shard_path.rchop(".cr")
        yield File.join(shard_src, "#{stem}.cr")
        yield File.join(shard_src, shard_name, "#{stem}.cr")
        yield File.join(joined, "#{basename}.cr")
        yield File.join(shard_src, shard_path, "#{stem}.cr")
        yield File.join(shard_src, shard_name, shard_path, "#{stem}.cr")
      else
        yield File.join(joined, "#{basename}.cr")
        yield File.join(joined, "src", "#{basename}.cr") unless relative
      end
    end
  end
end
