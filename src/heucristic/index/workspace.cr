require "./file"

module Heucristic
  module Index
    class Workspace
      def initialize : Nil
        @files = Hash(String, File).new
        @defs = Hash(String, Array(Def)).new
        @namespaces = Hash(String, Array(Namespace)).new
        @mixins = Hash(String, Array(Mixin)).new
        @instance_vars = Hash(String, Array(InstanceVar)).new
        @aliases = Hash(String, Array(Alias)).new
        @constants = Hash(String, Array(Constant)).new
      end

      def size : Int32
        @files.size
      end

      def update(file : File) : Nil
        remove(file.path)
        @files[file.path] = file
        file.defs.each { |entry| add(@defs, entry.name, entry) }
        file.namespaces.each { |entry| add(@namespaces, entry.name, entry) }
        file.mixins.each { |entry| add(@mixins, entry.owner, entry) }
        file.instance_vars.each { |entry| add(@instance_vars, entry.owner, entry) }
        file.aliases.each { |entry| add(@aliases, entry.name, entry) }
        file.constants.each { |entry| add(@constants, entry.name, entry) }
      end

      def replace_all(files : Array(File)) : Nil
        files.each { |file| update(file) }
      end

      def remove(path : String) : Nil
        previous = @files.delete(path)
        return unless previous

        previous.defs.each { |entry| drop(@defs, entry.name, path) }
        previous.namespaces.each { |entry| drop(@namespaces, entry.name, path) }
        previous.mixins.each { |entry| drop(@mixins, entry.owner, path) }
        previous.instance_vars.each { |entry| drop(@instance_vars, entry.owner, path) }
        previous.aliases.each { |entry| drop(@aliases, entry.name, path) }
        previous.constants.each { |entry| drop(@constants, entry.name, path) }
      end

      def named(name : String) : Array(Def)
        @defs[name]? || Array(Def).new
      end

      def namespaces(name : String) : Array(Namespace)
        @namespaces[name]? || Array(Namespace).new
      end

      def aliases(name : String) : Array(Alias)
        @aliases[name]? || Array(Alias).new
      end

      def constants(name : String) : Array(Constant)
        @constants[name]? || Array(Constant).new
      end

      def mixins_of(owner : String) : Array(Mixin)
        @mixins[owner]? || Array(Mixin).new
      end

      def instance_vars_of(owner : String) : Array(InstanceVar)
        @instance_vars[owner]? || Array(InstanceVar).new
      end

      private def add(table : Hash(String, Array(T)), key : String, entry : T) : Nil forall T
        (table[key] ||= Array(T).new) << entry
      end

      private def drop(table : Hash(String, Array(T)), key : String, path : String) : Nil forall T
        remaining = table[key]?
        return unless remaining

        remaining.reject! { |entry| entry.path == path }
        table.delete(key) if remaining.empty?
      end
    end
  end
end
