require "./file"
require "./sites"
require "./call_use"
require "./path_use"
require "./macro_target"
require "./macro_expansion"

module Heucristic
  module Index
    class Workspace
      def initialize : Nil
        @files = Hash(String, File).new
        @defs = Hash(String, Array(Def)).new
        @defs_by_owner = Hash(String, Array(Def)).new
        @namespaces = Hash(String, Array(Namespace)).new
        @enclosing = Hash(String, Array(Namespace)).new
        @mixins = Hash(String, Array(Mixin)).new
        @instance_vars = Hash(String, Array(InstanceVar)).new
        @aliases = Hash(String, Array(Alias)).new
        @constants = Hash(String, Array(Constant)).new
        @constants_by_owner = Hash(String, Array(Constant)).new
        @macros = Hash(String, Array(MacroDef)).new
        @macros_by_owner = Hash(String, Array(MacroDef)).new
        @opaque = Hash(String, Array(OpaqueBody)).new
        @aliases_by_owner = Hash(String, Array(Alias)).new
        @sites = Hash(String, Sites).new
        @call_uses = Hash(String, Array(CallUse)).new
        @path_uses = Hash(String, Array(PathUse)).new
        @expansions = Hash(MacroTarget, Hash(MacroExpansion::Key, MacroExpansion)).new
      end

      def size : Int32
        @files.size
      end

      def update(file : File) : Bool
        previous = @files[file.path]?
        remove(file.path)
        @files[file.path] = file
        changed = previous.nil? || previous.fingerprint != file.fingerprint
        file.defs.each do |entry|
          add(@defs, entry.name, entry)
          add(@defs_by_owner, owner_key(entry.owner), entry)
        end
        file.namespaces.each do |entry|
          add(@namespaces, entry.name, entry)
          each_enclosing(entry.name) { |prefix| add(@enclosing, prefix, entry) }
        end
        file.mixins.each { |entry| add(@mixins, owner_key(entry.owner), entry) }
        file.instance_vars.each { |entry| add(@instance_vars, entry.owner, entry) }
        file.aliases.each do |entry|
          add(@aliases, entry.name, entry)
          add(@aliases_by_owner, entry.name.rpartition("::")[0], entry)
        end
        file.opaque.each { |entry| add(@opaque, entry.owner, entry) }
        file.constants.each do |entry|
          add(@constants, entry.name, entry)
          add(@constants_by_owner, entry.name.rpartition("::")[0], entry)
        end
        file.macros.each do |entry|
          add(@macros, entry.name, entry)
          add(@macros_by_owner, owner_key(entry.owner), entry)
        end
        changed
      end

      def replace_all(files : Array(File)) : Nil
        files.each { |file| update(file) }
      end

      def expand(target : MacroTarget, expansions : Array(MacroExpansion)) : Nil
        @expansions[target] = expansions.to_h { |expansion| {expansion.key, expansion} }
      end

      def expansion(path : String, line : Int32, column : Int32) : MacroExpansion?
        key = MacroExpansion::Key.new(path, line, column)
        @expansions.each_value do |table|
          found = table[key]?
          return found if found
        end
        nil
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

        previous.defs.each do |entry|
          drop(@defs, entry.name, path)
          drop(@defs_by_owner, owner_key(entry.owner), path)
        end
        previous.namespaces.each do |entry|
          drop(@namespaces, entry.name, path)
          each_enclosing(entry.name) { |prefix| drop(@enclosing, prefix, path) }
        end
        previous.mixins.each { |entry| drop(@mixins, owner_key(entry.owner), path) }
        previous.instance_vars.each { |entry| drop(@instance_vars, entry.owner, path) }
        previous.aliases.each do |entry|
          drop(@aliases, entry.name, path)
          drop(@aliases_by_owner, entry.name.rpartition("::")[0], path)
        end
        previous.opaque.each { |entry| drop(@opaque, entry.owner, path) }
        previous.constants.each do |entry|
          drop(@constants, entry.name, path)
          drop(@constants_by_owner, entry.name.rpartition("::")[0], path)
        end
        previous.macros.each do |entry|
          drop(@macros, entry.name, path)
          drop(@macros_by_owner, owner_key(entry.owner), path)
        end
      end

      def named(name : String) : Array(Def)
        @defs[name]? || Array(Def).new
      end

      def defs_at(path : String, node : Crystal::Def) : Array(Def)
        location = node.name_location || node.location
        return Array(Def).new unless location

        line = (location.line_number - 1).to_u32
        named(node.name).select do |entry|
          entry.path == path && entry.name_span.start_line == line
        end
      end

      def defs_of(owner : Owner) : Array(Def)
        @defs_by_owner[owner_key(owner)]? || Array(Def).new
      end

      def namespaces(name : String) : Array(Namespace)
        @namespaces[name]? || Array(Namespace).new
      end

      def encloses?(name : String) : Bool
        @enclosing.has_key?(name)
      end

      def aliases(name : String) : Array(Alias)
        @aliases[name]? || Array(Alias).new
      end

      def constants(name : String) : Array(Constant)
        @constants[name]? || Array(Constant).new
      end

      def constants_of(owner : String) : Array(Constant)
        @constants_by_owner[owner]? || Array(Constant).new
      end

      def mixins_of(owner : Owner) : Array(Mixin)
        @mixins[owner_key(owner)]? || Array(Mixin).new
      end

      def each_mixin(& : Mixin ->) : Nil
        @mixins.each_value { |mixins| mixins.each { |mixin| yield mixin } }
      end

      def instance_vars_of(owner : String) : Array(InstanceVar)
        @instance_vars[owner]? || Array(InstanceVar).new
      end

      def macros(name : String) : Array(MacroDef)
        @macros[name]? || Array(MacroDef).new
      end

      def opaque?(owner : String) : Bool
        @opaque.has_key?(owner)
      end

      def member_names(owner : String) : Array(String)
        names = Array(String).new
        defs_of(owner).each { |entry| names << entry.name }
        macros_of(owner).each { |entry| names << entry.name }
        instance_vars_of(owner).each { |entry| names << entry.name }
        constants_of(owner).each { |entry| names << entry.name.rpartition("::")[2] }
        (@aliases_by_owner[owner]? || Array(Alias).new).each do |entry|
          names << entry.name.rpartition("::")[2]
        end
        (@enclosing[owner]? || Array(Namespace).new).each do |entry|
          names << entry.name[(owner.size + 2)..].partition("::")[0]
        end
        names
      end

      def macros_of(owner : Owner) : Array(MacroDef)
        @macros_by_owner[owner_key(owner)]? || Array(MacroDef).new
      end

      private def owner_key(owner : Owner) : String
        owner.is_a?(String) ? owner : ""
      end

      private def each_enclosing(name : String, & : String ->) : Nil
        offset = 0
        while (separator = name.index("::", offset))
          yield name[0, separator]
          offset = separator + 2
        end
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
