require "./file"
require "./macro_site"
require "./shims"
require "./workspace"
require "./accessor"
require "./synthesized"
require "../syntax/well_known"

module Heucristic
  module Index
    module Generated
      extend self

      def merge(file : File, sites : Array(MacroSite), workspace : Workspace, shims : Shims) : File
        macros = Hash(Int32, String).new
        sites.each { |site| macros[site.line] = site.macro_name }
        privately = Hash(Int32, String).new
        sites.each { |site| site.private_to.try { |path| privately[site.line] = path } }
        kept = file.defs.reject do |entry|
          constructor?(entry.name) ||
            known?(entry, workspace, shims, privately[entry.name_span.start_line.to_i + 1]?) ||
            synthesized?(entry, macros, workspace)
        end
        kept.map! do |entry|
          path = privately[entry.name_span.start_line.to_i + 1]?
          path ? entry.copy_with(private_path: path) : entry
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
        )
      end

      private def synthesized?(
        entry : Def,
        macros : Hash(Int32, String),
        workspace : Workspace,
      ) : Bool
        macro_name = macros[entry.name_span.start_line.to_i + 1]?
        return false unless macro_name && synthesized_macro?(macro_name)

        workspace.named(entry.name).any? do |existing|
          existing.path != entry.path && existing.owner == entry.owner &&
            existing.receiver == entry.receiver
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
        private_to : String?,
      ) : Bool
        return true if shims.find(entry)

        identity = entry.identity
        workspace.named(entry.name).any? do |existing|
          existing.path != entry.path && existing.identity == identity &&
            (private_to.nil? || existing.path == private_to)
        end
      end
    end
  end
end
