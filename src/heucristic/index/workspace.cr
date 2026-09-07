require "./file"

module Heucristic
  module Index
    class Workspace
      def initialize : Nil
        @files = Hash(String, File).new
        @by_name = Hash(String, Array(Def)).new
      end

      def size : Int32
        @files.size
      end

      def update(file : File) : Nil
        remove(file.path)
        @files[file.path] = file
        file.defs.each { |definition| (@by_name[definition.name] ||= Array(Def).new) << definition }
      end

      def replace_all(files : Array(File)) : Nil
        files.each { |file| update(file) }
      end

      def remove(path : String) : Nil
        previous = @files.delete(path)
        return unless previous

        previous.defs.each do |definition|
          remaining = @by_name[definition.name]?
          next unless remaining

          remaining.reject! { |candidate| candidate.path == path }
          @by_name.delete(definition.name) if remaining.empty?
        end
      end

      def named(name : String) : Array(Def)
        @by_name[name]? || Array(Def).new
      end
    end
  end
end
