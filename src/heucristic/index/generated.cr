require "./file"
require "./macro_site"
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
        workspace : Workspace,
        shims : Shims,
        loaded : LoadedFiles,
      ) : File
        macros = Hash(Int32, String).new
        sites.each { |site| macros[site.line] = site.macro_name }
        privately = Hash(Int32, String).new
        sites.each { |site| site.private_to.try { |path| privately[site.line] = path } }
        kept = file.defs.reject do |entry|
          private_to = privately[entry.name_span.start_line.to_i + 1]?
          constructor?(entry.name) || known?(entry, workspace, shims, loaded, private_to) ||
            synthesized?(entry, macros, workspace, loaded)
        end
        kept.map! do |entry|
          line = entry.name_span.start_line.to_i + 1
          path = privately[line]?
          entry = entry.copy_with(private_path: path) if path
          equality?(entry, macros[line]?) ? entry.copy_with(return_type: BOOLEAN) : entry
        end
        macros_kept = file.macros.reject do |entry|
          workspace.macros(entry.name).any? do |existing|
            existing.path != entry.path && existing.owner == entry.owner
          end
        end
        File.new(
          file.path,
          kept,
          file.namespaces,
          file.mixins,
          file.instance_vars,
          file.aliases,
          file.constants,
          macros_kept,
          file.opaque,
        )
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
