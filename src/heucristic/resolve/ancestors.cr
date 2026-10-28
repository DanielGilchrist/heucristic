require "../index/workspace"
require "./resolution"
require "./scope"
require "./builtins"
require "./binding"

module Heucristic
  module Resolve
    class Ancestors
      alias Chain = Array(String) | Unknown

      record Parent, name : String, arguments : Array(Syntax::Type)
      record NotAnAncestor

      def initialize(@workspace : Index::Workspace) : Nil
        @cache = Hash(String, Chain).new
      end

      def invalidate : Nil
        @cache.clear
      end

      def of(name : String, types : Types) : Chain
        @cache[name]? || (@cache[name] = compute(name, types, Array(String).new))
      end

      def bindings(receiver : TypeRef, target : String, types : Types) : Array(Binding) | Unknown
        bindings = bind(receiver.name, receiver.arguments)
        found = walk(receiver.name, bindings, target, types, Array(String).new)
        return found unless found.is_a?(NotAnAncestor)
        return Array(Binding).new if module?(receiver.name) && type_vars_of(target).empty?

        Unknown.new(:unresolved_name, "#{target} is not an ancestor of #{receiver}")
      end

      def type_vars_of(name : String) : Array(String)
        @workspace.namespaces(name).each do |entry|
          case entry
          in Index::ClassNamespace, Index::ModuleNamespace
            return entry.type_vars unless entry.type_vars.empty?
          in Index::EnumNamespace, Index::LibNamespace, Index::AnnotationNamespace
            nil
          end
        end
        Builtins.type_vars(name)
      end

      def splat_index_of(name : String) : Int32?
        @workspace.namespaces(name).each do |entry|
          return entry.splat_index if entry.is_a?(Index::ClassNamespace) && entry.splat_index
        end
        Builtins.splat_index(name)
      end

      private def module?(name : String) : Bool
        @workspace.namespaces(name).any?(Index::ModuleNamespace)
      end

      private def walk(
        name : String,
        bindings : Array(Binding),
        target : String,
        types : Types,
        visiting : Array(String),
      ) : Array(Binding) | Unknown | NotAnAncestor
        return bindings if name == target
        return NotAnAncestor.new if visiting.includes?(name)

        parents = parents(name, types)
        return parents if parents.is_a?(Unknown)

        scope = Scope.new(name, type_vars_of(name), bindings)
        parents.each do |parent|
          arguments = parent.arguments.map { |argument| types.resolve(argument, scope) }
          found = walk(parent.name, bind(parent.name, arguments), target, types, visiting + [name])
          return found unless found.is_a?(NotAnAncestor)
        end
        NotAnAncestor.new
      end

      private def bind(name : String, arguments : Array(Resolution)) : Array(Binding)
        type_vars = type_vars_of(name)
        return Array(Binding).new if arguments.empty?

        splat = splat_index_of(name)
        return bind_positional(type_vars, arguments) unless splat && splat < type_vars.size

        trailing = type_vars.size - splat - 1
        packed = arguments.size - splat - trailing
        return bind_positional(type_vars, arguments) if packed < 0

        bindings = bind_positional(type_vars[0, splat], arguments[0, splat])
        pack = TypeRef.of(:tuple, arguments[splat, packed])
        bindings << Binding.new(type_vars[splat], pack)
        bindings.concat(bind_positional(type_vars[(splat + 1)..], arguments[(splat + packed)..]))
      end

      private def bind_positional(
        type_vars : Array(String),
        arguments : Array(Resolution),
      ) : Array(Binding)
        bindings = Array(Binding).new(type_vars.size)
        type_vars.zip?(arguments) do |type_var, argument|
          bindings << Binding.new(type_var, argument) if argument
        end
        bindings
      end

      private def compute(name : String, types : Types, visiting : Array(String)) : Chain
        return Unknown.new(:cycle, name) if visiting.includes?(name)

        parents = parents(name, types)
        return parents if parents.is_a?(Unknown)

        chain = Array(String).new
        parents.each do |parent|
          chain << parent.name
          inherited = compute(parent.name, types, visiting + [name])
          return inherited if inherited.is_a?(Unknown)
          inherited.each { |ancestor| chain << ancestor unless chain.includes?(ancestor) }
        end
        chain
      end

      private def parents(name : String, types : Types) : Array(Parent) | Unknown
        entries = @workspace.namespaces(name)
        return builtin_parents(name) if entries.empty?

        parents = Array(Parent).new
        @workspace.mixins_of(name).reverse_each do |mixin|
          next unless mixin.kind.include?

          parent = resolve_parent(mixin.target, name, types)
          return parent if parent.is_a?(Unknown)
          parents << parent unless parents.any?(&.name.==(parent.name))
        end

        case (superclass = superclass(entries, name, types))
        in Unknown                then superclass
        in Builtins::NoSuperclass then parents
        in Parent                 then parents << superclass
        end
      end

      private def builtin_parents(name : String) : Array(Parent) | Unknown
        return Unknown.new(:unresolved_name, name) unless Builtins.includes?(name)

        case (superclass = Builtins.superclass(name))
        in Builtins::NoSuperclass then Array(Parent).new
        in String                 then [Parent.new(superclass, Array(Syntax::Type).new)]
        end
      end

      private def superclass(
        entries : Array(Index::Namespace),
        name : String,
        types : Types,
      ) : Parent | Builtins::NoSuperclass | Unknown
        entries.each do |entry|
          case entry
          in Index::ClassNamespace
            stated = entry.superclass
            next if stated.is_a?(Index::Unrestricted)
            return resolve_parent(stated, name, types)
          in Index::EnumNamespace
            return Parent.new(CoreType::Enum.type_name, Array(Syntax::Type).new)
          in Index::ModuleNamespace, Index::LibNamespace, Index::AnnotationNamespace
            return Builtins::NoSuperclass.new
          end
        end

        implicit_superclass(entries[0])
      end

      private def implicit_superclass(entry : Index::Namespace) : Parent | Builtins::NoSuperclass
        return Builtins::NoSuperclass.new unless entry.is_a?(Index::ClassNamespace)

        name = if Builtins.includes?(entry.name)
                 Builtins.superclass(entry.name)
               else
                 (entry.kind.struct? ? CoreType::Struct : CoreType::Reference).type_name
               end
        return name if name.is_a?(Builtins::NoSuperclass)

        Parent.new(name, Array(Syntax::Type).new)
      end

      private def resolve_parent(
        target : Syntax::TypeReader::Outcome,
        owner : String,
        types : Types,
      ) : Parent | Unknown
        if target.is_a?(Syntax::TypeReader::Unsupported)
          return Unknown.new(:unsupported, target.source)
        end

        resolved = types.resolve_lexically(target, Scope.new(owner, type_vars_of(owner)))
        case resolved
        in TypeRef then Parent.new(resolved.name, generic_arguments(target))
        in Unknown then resolved
        in UnionRef, MetaRef, TypeVar
          Unknown.new(:unsupported, "#{owner} inherits from #{resolved}")
        end
      end

      private def generic_arguments(target : Syntax::Type) : Array(Syntax::Type)
        target.is_a?(Syntax::Generic) ? target.arguments : Array(Syntax::Type).new
      end
    end
  end
end
