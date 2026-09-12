require "../index/workspace"
require "../resolve/types"
require "../resolve/scope"
require "../resolve/resolution"
require "./macro_uses"
require "../core_type"

module Heucristic
  module Check
    class Settled
      GENERATED = "<macros>"

      def initialize(
        @workspace : Index::Workspace,
        @types : Resolve::Types,
        @complete : Bool,
        @dirty : Set(String),
        @compiled : Set(String),
        @root : String,
        @shim_roots : Array(String),
      ) : Nil
        @unsettled_files = Hash(String, Bool).new
        @settled_types = Hash(String, Bool).new
        @declared_types = Hash(String, Bool).new
        @extended = nil.as(Set(String)?)
      end

      def type?(name : String) : Bool
        @settled_types[name] ||= settled_type?(name)
      end

      def declared?(name : String) : Bool
        @declared_types[name] ||= declared_type?(name)
      end

      def namespace?(name : String) : Bool
        type?(name) || declared?(name)
      end

      def compiled_level?(name : String) : Bool
        @workspace.namespaces(name).any? { |entry| compiled?(entry.path) }
      end

      def program? : Bool
        return false unless ready?

        @dirty.none? { |path| unsettled_file?(path) }
      end

      def extended?(name : String) : Bool
        (@extended ||= compute_extended).includes?(name)
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
        path == GENERATED || @compiled.includes?(path)
      end

      private def declared_in_project?(entry : Index::Namespace) : Bool
        path = entry.path
        return true if path == GENERATED
        return false unless path.starts_with?(@root + "/")
        return false if path.starts_with?(File.join(@root, "lib") + "/")

        @shim_roots.none? { |shim_root| path.starts_with?(shim_root + "/") }
      end

      private def unsettled_file?(path : String) : Bool
        return false unless @dirty.includes?(path)

        @unsettled_files[path] ||= begin
          sites = @workspace.sites(path)
          sites.nil? || MacroUses.any?(sites, @workspace)
        end
      end

      private def compute_extended : Set(String)
        extended = Set(String).new
        @workspace.each_file do |file|
          file.namespaces.each do |entry|
            next unless entry.is_a?(Index::ClassNamespace)

            parent = superclass_of(entry)
            extended << parent if parent
          end
        end
        extended
      end

      private def superclass_of(entry : Index::ClassNamespace) : String?
        superclass = entry.superclass
        return unless superclass.is_a?(Syntax::Type)

        scope = Resolve::Scope.new(entry.name, entry.type_vars)
        resolved = @types.resolve_lexically(superclass, scope)
        resolved.is_a?(Resolve::TypeRef) ? resolved.name : nil
      end
    end
  end
end
