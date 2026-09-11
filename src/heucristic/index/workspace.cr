require "./file"
require "./sites"
require "./call_use"
require "./path_use"

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
        @sites = Hash(String, Sites).new
        @call_uses = Hash(String, Array(CallUse)).new
        @path_uses = Hash(String, Array(PathUse)).new
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

      def update_sites(sites : Sites) : Nil
        remove_sites(sites.path)
        @sites[sites.path] = sites
        sites.calls.each do |site|
          add(@call_uses, site.call.name, CallUse.new(sites, site.call, site.context))
        end
        sites.paths.each do |site|
          add(@path_uses, site.path.names.last, PathUse.new(sites, site.path, site.context))
        end
      end

      def replace_sites(all : Array(Sites)) : Nil
        all.each { |sites| update_sites(sites) }
      end

      def remove_sites(path : String) : Nil
        previous = @sites.delete(path)
        return unless previous

        previous.calls.each do |site|
          @call_uses[site.call.name]?.try(&.reject!(&.sites.path.==(path)))
        end
        previous.paths.each do |site|
          @path_uses[site.path.names.last]?.try(&.reject!(&.sites.path.==(path)))
        end
      end

      def file(path : String) : File?
        @files[path]?
      end

      def each_file(& : File ->) : Nil
        @files.each_value { |file| yield file }
      end

      def sites(path : String) : Sites?
        @sites[path]?
      end

      def each_sites(& : Sites ->) : Nil
        @sites.each_value { |sites| yield sites }
      end

      def call_uses(name : String) : Array(CallUse)
        @call_uses[name]? || Array(CallUse).new
      end

      def path_uses(last : String) : Array(PathUse)
        @path_uses[last]? || Array(PathUse).new
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

      def each_mixin(& : Mixin ->) : Nil
        @mixins.each_value { |mixins| mixins.each { |mixin| yield mixin } }
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
