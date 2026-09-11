require "./file"
require "./macro_site"
require "./shims"
require "./workspace"

module Heucristic
  module Index
    module Generated
      extend self

      SYNTHESIZED = {
        "getter", "getter?", "getter!", "property", "property?", "property!", "setter",
        "class_getter", "class_getter?", "class_getter!", "class_property", "class_property?",
        "class_property!", "class_setter", "delegate", "record",
      }

      def merge(file : File, sites : Array(MacroSite), workspace : Workspace, shims : Shims) : File
        macros = Hash(Int32, String).new
        sites.each { |site| macros[site.line] = site.macro_name }
        kept = file.defs.reject do |entry|
          known?(entry, workspace, shims) || synthesized?(entry, macros, workspace)
        end
        File.new(
          file.path,
          kept,
          file.namespaces,
          file.mixins,
          file.instance_vars,
          file.aliases,
          file.constants,
        )
      end

      private def synthesized?(
        entry : Def,
        macros : Hash(Int32, String),
        workspace : Workspace,
      ) : Bool
        macro_name = macros[entry.name_span.start_line.to_i + 1]?
        return false unless macro_name && SYNTHESIZED.includes?(macro_name)

        workspace.named(entry.name).any? do |existing|
          existing.path != entry.path && existing.owner == entry.owner &&
            existing.receiver == entry.receiver
        end
      end

      private def known?(entry : Def, workspace : Workspace, shims : Shims) : Bool
        return true if shims.find(entry)

        identity = entry.identity
        workspace.named(entry.name).any? do |existing|
          existing.path != entry.path && existing.identity == identity
        end
      end
    end
  end
end
