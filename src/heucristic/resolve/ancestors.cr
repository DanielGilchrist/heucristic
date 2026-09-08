require "../index/workspace"
require "./resolution"
require "./scope"
require "./builtins"

module Heucristic
  module Resolve
    class Ancestors
      alias Chain = Array(String) | Unknown

      def initialize(@workspace : Index::Workspace) : Nil
        @cache = Hash(String, Chain).new
      end

      def invalidate : Nil
        @cache.clear
      end

      def of(name : String, types : Types) : Chain
        @cache[name]? || (@cache[name] = compute(name, types, Array(String).new))
      end

      private def compute(name : String, types : Types, visiting : Array(String)) : Chain
        return Unknown.new(:cycle, name) if visiting.includes?(name)

        parents = parents(name, types)
        return parents if parents.is_a?(Unknown)

        chain = Array(String).new
        parents.each do |parent|
          chain << parent
          inherited = compute(parent, types, visiting + [name])
          return inherited if inherited.is_a?(Unknown)
          inherited.each { |ancestor| chain << ancestor unless chain.includes?(ancestor) }
        end
        chain
      end

      private def parents(name : String, types : Types) : Chain
        entries = @workspace.namespaces(name)
        return builtin_parents(name) if entries.empty?

        parents = Array(String).new
        @workspace.mixins_of(name).reverse_each do |mixin|
          next unless mixin.kind.include?

          target = resolve_parent(mixin.target, name, types)
          return target if target.is_a?(Unknown)
          parents << target unless parents.includes?(target)
        end

        case (superclass = superclass(entries, name, types))
        in Unknown                then superclass
        in Builtins::NoSuperclass then parents
        in String                 then parents << superclass
        end
      end

      private def builtin_parents(name : String) : Chain
        return Unknown.new(:unresolved_name, name) unless Builtins.includes?(name)

        case (superclass = Builtins.superclass(name))
        in Builtins::NoSuperclass then Array(String).new
        in String                 then [superclass]
        end
      end

      private def superclass(
        entries : Array(Index::Namespace),
        name : String,
        types : Types,
      ) : String | Builtins::NoSuperclass | Unknown
        entries.each do |entry|
          case entry
          in Index::ClassNamespace
            stated = entry.superclass
            next if stated.is_a?(Index::Unrestricted)
            return resolve_parent(stated, name, types)
          in Index::EnumNamespace
            return "Enum"
          in Index::ModuleNamespace, Index::LibNamespace, Index::AnnotationNamespace
            return Builtins::NoSuperclass.new
          end
        end

        implicit_superclass(entries[0])
      end

      private def implicit_superclass(entry : Index::Namespace) : String | Builtins::NoSuperclass
        return Builtins::NoSuperclass.new unless entry.is_a?(Index::ClassNamespace)

        entry.kind.struct? ? "Struct" : "Reference"
      end

      private def resolve_parent(
        target : Syntax::TypeReader::Outcome,
        owner : String,
        types : Types,
      ) : String | Unknown
        if target.is_a?(Syntax::TypeReader::Unsupported)
          return Unknown.new(:unsupported, target.source)
        end

        resolved = types.resolve_lexically(target, Scope.of(owner))
        case resolved
        in TypeRef then resolved.name
        in Unknown then resolved
        in UnionRef, MetaRef
          Unknown.new(:unsupported, "#{owner} inherits from #{resolved}")
        end
      end
    end
  end
end
