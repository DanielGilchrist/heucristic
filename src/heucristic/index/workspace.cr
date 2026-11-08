require "../crystal_version"
require "./file"
require "./table"
require "./sites"
require "./call_use"
require "./path_use"
require "./macro_target"
require "./macro_expansion"

module Heucristic
  module Index
    class Workspace
      enum Change
        Add
        Drop

        def apply(table : Table(K, T), key : K, entry : T, path : String) : Nil forall K, T
          case self
          in .add?  then table.add(key, entry)
          in .drop? then table.drop(key, &.path.==(path))
          end
        end
      end

      getter crystal_version : CrystalVersion::Detected

      def initialize : Nil
        @crystal_version = CrystalVersion::Unknown.new("Crystal version not detected")
        @files = Hash(String, File).new
        @defs = Table(String, Def).new
        @defs_by_owner = Table(Owner, Def).new
        @namespaces = Table(Identity, Namespace).new
        @enclosing = Table(Identity, Namespace).new
        @mixins = Table(Owner, Mixin).new
        @instance_vars = Table(Identity, InstanceVar).new
        @aliases = Table(Identity, Alias).new
        @constants = Table(Identity, Constant).new
        @constants_by_owner = Table(Owner, Constant).new
        @macros = Table(String, MacroDef).new
        @macros_by_owner = Table(Owner, MacroDef).new
        @opaque = Table(Identity, OpaqueBody).new
        @aliases_by_owner = Table(Owner, Alias).new
        @sites = Hash(String, Sites).new
        @private_counts = Hash(String, Int32).new
        @call_uses = Table(String, CallUse).new
        @path_uses = Table(String, PathUse).new
        @expansions = Hash(MacroTarget, Hash(MacroExpansion::Key, MacroExpansion)).new
      end

      def crystal_version=(version : CrystalVersion::Detected) : CrystalVersion::Detected
        @crystal_version = version
      end

      def size : Int32
        @files.size
      end

      def update(file : File) : Bool
        previous = @files[file.path]?
        remove(file.path)
        @files[file.path] = file
        apply(file, Change::Add)
        previous.nil? || previous.fingerprint != file.fingerprint
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
          @call_uses.add(site.call.name, CallUse.new(sites, site.call, site.context))
        end
        sites.paths.each do |site|
          @path_uses.add(site.path.names.last, PathUse.new(sites, site.path, site.context))
        end
      end

      def replace_sites(all : Array(Sites)) : Nil
        all.each { |sites| update_sites(sites) }
      end

      def remove_sites(path : String) : Nil
        previous = @sites.delete(path)
        return unless previous

        previous.calls.each do |site|
          @call_uses.drop(site.call.name, &.sites.path.==(path))
        end
        previous.paths.each do |site|
          @path_uses.drop(site.path.names.last, &.sites.path.==(path))
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
        @call_uses.entries(name)
      end

      def path_uses(last : String) : Array(PathUse)
        @path_uses.entries(last)
      end

      def remove(path : String) : Nil
        previous = @files.delete(path)
        return unless previous

        apply(previous, Change::Drop)
      end

      def named(name : String) : Array(Def)
        @defs.entries(name)
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
        @defs_by_owner.entries(owner)
      end

      def namespaces(identity : Identity) : Array(Namespace)
        @namespaces.entries(identity)
      end

      def private_to?(path : String) : Bool
        @private_counts.has_key?(path)
      end

      def module?(identity : Identity) : Bool
        namespaces(identity).any?(ModuleNamespace)
      end

      def enum?(identity : Identity) : Bool
        namespaces(identity).any?(EnumNamespace)
      end

      def lib?(identity : Identity) : Bool
        namespaces(identity).any?(LibNamespace)
      end

      def encloses?(identity : Identity) : Bool
        @enclosing.has_key?(identity)
      end

      def enclosed(identity : Identity) : Array(Namespace)
        @enclosing.entries(identity)
      end

      def aliases(identity : Identity) : Array(Alias)
        @aliases.entries(identity)
      end

      def constants(identity : Identity) : Array(Constant)
        @constants.entries(identity)
      end

      def constants_of(owner : Owner) : Array(Constant)
        @constants_by_owner.entries(owner)
      end

      def mixins_of(owner : Owner) : Array(Mixin)
        @mixins.entries(owner)
      end

      def each_mixin(& : Mixin ->) : Nil
        @mixins.each_group { |mixins| mixins.each { |mixin| yield mixin } }
      end

      def instance_vars_of(owner : Identity) : Array(InstanceVar)
        @instance_vars.entries(owner)
      end

      def macros(name : String) : Array(MacroDef)
        @macros.entries(name)
      end

      def opaque?(owner : Identity) : Bool
        @opaque.has_key?(owner)
      end

      def member_names(owner : Identity) : Array(String)
        names = Array(String).new
        defs_of(owner).each { |entry| names << entry.name }
        macros_of(owner).each { |entry| names << entry.name }
        instance_vars_of(owner).each { |entry| names << entry.name }
        constants_of(owner).each { |entry| names << entry.identity.last }
        @aliases_by_owner.entries(owner).each do |entry|
          names << entry.identity.last
        end
        @enclosing.entries(owner).each do |entry|
          names << entry.name[(owner.name.size + 2)..].partition("::")[0]
        end
        names
      end

      def macros_of(owner : Owner) : Array(MacroDef)
        @macros_by_owner.entries(owner)
      end

      private def track(identity : Identity, change : Change) : Nil
        return unless identity.is_a?(FilePrivate)

        count = @private_counts.fetch(identity.path, 0) + (change.add? ? 1 : -1)
        if count > 0
          @private_counts[identity.path] = count
        else
          @private_counts.delete(identity.path)
        end
      end

      private def each_enclosing(identity : Identity, & : Identity ->) : Nil
        current = identity.parent
        while current.is_a?(Identity)
          yield current
          current = current.parent
        end
      end

      private def apply(file : File, change : Change) : Nil
        path = file.path
        file.defs.each do |entry|
          change.apply(@defs, entry.name, entry, path)
          change.apply(@defs_by_owner, entry.owner, entry, path)
        end
        file.namespaces.each do |entry|
          track(entry.identity, change)
          change.apply(@namespaces, entry.identity, entry, path)
          each_enclosing(entry.identity) { |prefix| change.apply(@enclosing, prefix, entry, path) }
        end
        file.mixins.each { |entry| change.apply(@mixins, entry.owner, entry, path) }
        file.instance_vars.each { |entry| change.apply(@instance_vars, entry.owner, entry, path) }
        file.aliases.each do |entry|
          track(entry.identity, change)
          change.apply(@aliases, entry.identity, entry, path)
          change.apply(@aliases_by_owner, entry.identity.parent, entry, path)
        end
        file.opaque.each { |entry| change.apply(@opaque, entry.owner, entry, path) }
        file.constants.each do |entry|
          track(entry.identity, change)
          change.apply(@constants, entry.identity, entry, path)
          change.apply(@constants_by_owner, entry.identity.parent, entry, path)
        end
        file.macros.each do |entry|
          change.apply(@macros, entry.name, entry, path)
          change.apply(@macros_by_owner, entry.owner, entry, path)
        end
      end
    end
  end
end
