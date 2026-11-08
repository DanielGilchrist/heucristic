require "./file"
require "./macro_site"
require "./private_owners"
require "./reopening"
require "./shims"
require "./workspace"
require "./accessor"
require "./synthesized"
require "./loaded_files"
require "../syntax/type"
require "../syntax/well_known"

module Heucristic
  module Index
    module Generated
      extend self

      EQUALITY_MACROS = {"def_equals", "def_equals_and_hash", "record"}
      BOOLEAN         = Syntax::Named.new(["Bool"], true)

      def merge(
        file : File,
        sites : Array(MacroSite),
        reopenings : Array(Reopening),
        workspace : Workspace,
        shims : Shims,
        loaded : LoadedFiles,
      ) : File
        macros = Hash(Int32, String).new
        sites.each { |site| macros[site.line] = site.macro_name }
        privately = Hash(Int32, String).new
        sites.each { |site| site.private_to.try { |path| privately[site.line] = path } }
        privates = PrivateOwners.of(sites, reopenings)
        kept = Array(Def).new(file.defs.size)
        file.defs.each do |original|
          line = original.name_span.start_line.to_i + 1
          private_to = privately[line]?
          entry = private_to ? privatised(original, private_to) : original
          next if constructor?(entry.name) ||
                  known?(entry, workspace, shims, loaded, private_to) ||
                  synthesized?(entry, macros, workspace, loaded)

          kept << (equality?(entry, macros[line]?) ? entry.copy_with(return_type: BOOLEAN) : entry)
        end
        macros_kept = file.macros.reject do |entry|
          workspace.macros(entry.name).any? do |existing|
            existing.path != entry.path && existing.owner == privates.retarget(entry.owner)
          end
        end
        File.new(
          file.path,
          kept,
          file.namespaces.compact_map do |item|
            privates.retarget(item.identity).try { |identity| item.copy_with(identity: identity) }
          end,
          file.mixins.compact_map do |item|
            privates.retarget(item.owner).try { |owner| item.copy_with(owner: owner) }
          end,
          file.instance_vars.compact_map do |item|
            privates.retarget(item.owner).try { |owner| item.copy_with(owner: owner) }
          end,
          file.aliases.compact_map do |item|
            privates.retarget(item.identity).try { |identity| item.copy_with(identity: identity) }
          end,
          file.constants.compact_map do |item|
            privates.retarget(item.identity).try { |identity| item.copy_with(identity: identity) }
          end,
          macros_kept.compact_map do |item|
            privates.retarget(item.owner).try { |owner| item.copy_with(owner: owner) }
          end,
          file.opaque.compact_map do |item|
            privates.retarget(item.owner).try { |owner| item.copy_with(owner: owner) }
          end,
        )
      end

      private def privatised(entry : Def, path : String) : Def
        owner = entry.owner
        return entry.copy_with(private_path: path) unless owner.is_a?(Identity)

        entry.copy_with(owner: FilePrivate.new(owner.name, path), private_path: path)
      end

      private def equality?(entry : Def, macro_name : String?) : Bool
        return false unless macro_name && EQUALITY_MACROS.includes?(macro_name)

        entry.name == "==" && entry.return_type.is_a?(Unrestricted)
      end

      private def synthesized?(
        entry : Def,
        macros : Hash(Int32, String),
        workspace : Workspace,
        loaded : LoadedFiles,
      ) : Bool
        macro_name = macros[entry.name_span.start_line.to_i + 1]?
        return false unless macro_name && synthesized_macro?(macro_name)

        workspace.named(entry.name).any? do |existing|
          existing.path != entry.path && loaded.includes?(existing.path) &&
            existing.owner == entry.owner && existing.receiver == entry.receiver
        end
      end

      private def constructor?(name : String) : Bool
        known = Syntax::WellKnown.from_name(name)
        !known.nil? && (known.new? || known.allocate?)
      end

      private def synthesized_macro?(name : String) : Bool
        return true if Accessor.from_name(name)

        synthesized = Synthesized.from_name(name)
        !synthesized.nil? && (synthesized.record? || synthesized.delegate?)
      end

      private def known?(
        entry : Def,
        workspace : Workspace,
        shims : Shims,
        loaded : LoadedFiles,
        private_to : String?,
      ) : Bool
        return true if shims.find(entry)

        identity = entry.identity
        workspace.named(entry.name).any? do |existing|
          existing.path != entry.path && loaded.includes?(existing.path) &&
            existing.identity == identity && (private_to.nil? || existing.path == private_to)
        end
      end
    end
  end
end
