require "../index/workspace"
require "../resolve/types"
require "../resolve/scope"
require "../resolve/resolution"
require "../resolve/descendants"
require "./macro_uses"
require "../core_type"
require "../index/macro_hook"
require "../index/macro_target"

module Heucristic
  module Check
    class Settled
      def initialize(
        @workspace : Index::Workspace,
        @types : Resolve::Types,
        @descendants : Resolve::Descendants,
        @complete : Bool,
        @dirty : Set(String),
        @compiled : Set(String),
        @root : String,
        @shim_roots : Array(String),
        @open : Set(String) = Set(String).new,
      ) : Nil
        @unsettled_files = Hash(String, Bool).new
        @settled_types = Hash(String, Bool).new
        @declared_types = Hash(String, Bool).new
      end

      def type?(name : String) : Bool
        @settled_types.fetch(name) { @settled_types[name] = settled_type?(name) }
      end

      def declared?(name : String) : Bool
        @declared_types.fetch(name) { @declared_types[name] = declared_type?(name) }
      end

      def namespace?(name : String) : Bool
        type?(name) || declared?(name)
      end

      def uncompiled_file?(path : String) : Bool
        return false if !ready? || @compiled.empty? || @open.includes?(path)
        return false if Index::MacroTarget.generated?(path)
        return false unless path.starts_with?(@root + "/")
        return false if path.starts_with?(File.join(@root, "lib") + "/")
        return false if @shim_roots.any? { |shim_root| path.starts_with?(shim_root + "/") }

        !@compiled.includes?(path)
      end

      def project_type?(name : String) : Bool
        entries = @workspace.namespaces(name)
        !entries.empty? && entries.all? { |entry| declared_in_project?(entry) }
      end

      def generated_free?(name : String) : Bool
        chain = @types.ancestors(name)
        levels = chain.is_a?(Resolve::Unknown) ? [name] : [name] + chain
        generated = levels.any? do |level|
          @workspace.defs_of(level).any? { |entry| Index::MacroTarget.generated?(entry.path) }
        end
        return false if generated

        Index::MacroHook.values.none? do |hook|
          next false unless hook.generates_defs?

          @workspace.macros(hook.macro_name).any? { |entry| levels.includes?(entry.owner) }
        end
      end

      def compiled_level?(name : String) : Bool
        @workspace.namespaces(name).any? { |entry| compiled?(entry.path) }
      end

      def program? : Bool
        return false unless ready?

        @dirty.none? { |path| unsettled_file?(path) }
      end

      def extended?(name : String) : Bool
        @descendants.extended?(name)
      end

      def descendants(name : String) : Array(String)
        @descendants.of(name)
      end

      private def settled_type?(name : String) : Bool
        return false unless ready?

        entries = @workspace.namespaces(name)
        return false if entries.empty?
        return false unless entries.any? { |entry| compiled?(entry.path) }

        chain = @types.ancestors(name)
        return false if chain.is_a?(Resolve::Unknown)

        levels = [name] + chain
        levels.all? { |level| settled_level?(level) } && !missing_handler?(levels)
      end

      private def declared_type?(name : String) : Bool
        return false unless ready?

        entries = @workspace.namespaces(name)
        return false if entries.empty?
        return false unless entries.all? { |entry| declared_in_project?(entry) }
        return false if entries.any? { |entry| !compiled?(entry.path) && macro_uses?(entry.path) }

        chain = @types.ancestors(name)
        return false if chain.is_a?(Resolve::Unknown)

        chain.all? { |level| settled_level?(level) } && !missing_handler?([name] + chain)
      end

      private def macro_uses?(path : String) : Bool
        sites = @workspace.sites(path)
        sites.nil? || MacroUses.any?(sites, @workspace)
      end

      private def ready? : Bool
        @complete && !@workspace.namespaces(CoreType::Object.type_name).empty?
      end

      private def settled_level?(level : String) : Bool
        entries = @workspace.namespaces(level)
        return false if entries.empty?

        entries.none? { |entry| entry.is_a?(Index::LibNamespace) || unsettled_file?(entry.path) }
      end

      private def missing_handler?(levels : Array(String)) : Bool
        @workspace.named("method_missing").any? { |entry| levels.includes?(entry.owner) } ||
          @workspace.macros("method_missing").any? { |entry| levels.includes?(entry.owner) }
      end

      private def compiled?(path : String) : Bool
        Index::MacroTarget.generated?(path) || @compiled.includes?(path)
      end

      private def declared_in_project?(entry : Index::Namespace) : Bool
        path = entry.path
        return true if Index::MacroTarget.generated?(path)
        return false unless path.starts_with?(@root + "/")
        return false if path.starts_with?(File.join(@root, "lib") + "/")

        @shim_roots.none? { |shim_root| path.starts_with?(shim_root + "/") }
      end

      private def unsettled_file?(path : String) : Bool
        return false unless @dirty.includes?(path)

        @unsettled_files.fetch(path) do
          sites = @workspace.sites(path)
          @unsettled_files[path] = sites.nil? || MacroUses.any?(sites, @workspace)
        end
      end
    end
  end
end
