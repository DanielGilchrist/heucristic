require "../index/workspace"
require "./resolution"
require "./scope"
require "./builtins"
require "./binding"
require "../index/mixin_order"
require "../index/macro_hook"

module Heucristic
  module Resolve
    class Ancestors
      alias Chain = Array(Index::Identity) | Unknown

      record Parent,
        identity : Index::Identity,
        arguments : Array(Syntax::Type),
        declared_in : String?
      record NotAnAncestor

      def initialize(@workspace : Index::Workspace) : Nil
        @cache = Hash(Index::Identity, Chain).new
        @judging = Array(Index::Identity).new
      end

      def invalidate : Nil
        @cache.clear
      end

      def of(identity : Index::Identity, types : Types) : Chain
        cached = @cache[identity]?
        return cached if cached

        @cache[identity] = compute(identity, types, Array(Index::Identity).new)
      end

      def bindings(
        receiver : TypeRef,
        target : Index::Identity,
        types : Types,
      ) : Array(Binding) | Unknown
        bindings = bind(receiver.identity, receiver.arguments)
        found = walk(receiver.identity, bindings, target, types, Array(Index::Identity).new)
        return found unless found.is_a?(NotAnAncestor)
        module_target = @workspace.module?(receiver.identity) && type_vars_of(target).empty?
        return Array(Binding).new if module_target

        Unknown.new(:unresolved_name, "#{target} is not an ancestor of #{receiver}")
      end

      def type_vars_of(identity : Index::Identity) : Array(String)
        @workspace.namespaces(identity).each do |entry|
          case entry
          in Index::ClassNamespace, Index::ModuleNamespace
            return entry.type_vars unless entry.type_vars.empty?
          in Index::EnumNamespace, Index::LibNamespace, Index::AnnotationNamespace
            nil
          end
        end
        builtin(identity, Array(String).new) { |name| Builtins.type_vars(name) }
      end

      def splat_index_of(identity : Index::Identity) : Int32?
        @workspace.namespaces(identity).each do |entry|
          return entry.splat_index if entry.is_a?(Index::ClassNamespace) && entry.splat_index
        end
        builtin(identity, nil) { |name| Builtins.splat_index(name) }
      end

      private def builtin(
        identity : Index::Identity,
        fallback : N,
        & : String -> R
      ) : N | R forall N, R
        case identity
        in Index::Public      then yield identity.name
        in Index::FilePrivate then fallback
        end
      end

      private def walk(
        identity : Index::Identity,
        bindings : Array(Binding),
        target : Index::Identity,
        types : Types,
        visiting : Array(Index::Identity),
      ) : Array(Binding) | Unknown | NotAnAncestor
        return bindings if identity == target
        return NotAnAncestor.new if visiting.includes?(identity)

        parents = parents(identity, types)
        return parents if parents.is_a?(Unknown)

        scope = Scope.new(identity, type_vars_of(identity), bindings)
        parents.each do |parent|
          declaring = scope.at(parent.declared_in)
          arguments = parent.arguments.map { |argument| types.resolve(argument, declaring) }
          found = walk(
            parent.identity, bind(parent.identity, arguments), target, types, visiting + [identity]
          )
          return found unless found.is_a?(NotAnAncestor)
        end
        NotAnAncestor.new
      end

      private def bind(identity : Index::Identity, arguments : Array(Resolution)) : Array(Binding)
        type_vars = type_vars_of(identity)
        return Array(Binding).new if arguments.empty?

        splat = splat_index_of(identity)
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

      private def compute(
        identity : Index::Identity,
        types : Types,
        visiting : Array(Index::Identity),
      ) : Chain
        return Unknown.new(:cycle, identity.name) if visiting.includes?(identity)

        parents = parents(identity, types)
        return parents if parents.is_a?(Unknown)

        chain = Array(Index::Identity).new
        parents.each do |parent|
          chain << parent.identity unless chain.includes?(parent.identity)
          inherited = compute(parent.identity, types, visiting + [identity])
          return inherited if inherited.is_a?(Unknown)
          inherited.each { |ancestor| chain << ancestor unless chain.includes?(ancestor) }
        end
        chain
      end

      private def parents(identity : Index::Identity, types : Types) : Array(Parent) | Unknown
        entries = @workspace.namespaces(identity)
        return builtin_parents(identity) if entries.empty?

        declared = Index::MixinOrder.declared(@workspace.mixins_of(identity), :include)
        mixins = case declared
                 in Array(Index::Mixin) then declared
                 in Index::MixinOrder::Unordered
                   unless interchangeable?(identity, declared.mixins, types)
                     return Unknown.new(
                       :ambiguous, "#{identity} has includes in an unknown order"
                     )
                   end

                   declared.mixins
                 end

        parents = Array(Parent).new(mixins.size + 1)
        mixins.each do |mixin|
          parent = resolve_parent(mixin.target, identity, mixin.path, types)
          return parent if parent.is_a?(Unknown)
          parents << parent unless parents.any?(&.identity.==(parent.identity))
        end
        parents.reverse!

        case (superclass = superclass(entries, identity, types))
        in Unknown                then superclass
        in Builtins::NoSuperclass then parents
        in Parent                 then parents << superclass
        end
      end

      private def interchangeable?(
        owner : Index::Identity,
        mixins : Array(Index::Mixin),
        types : Types,
      ) : Bool
        return false if @judging.includes?(owner)

        @judging << owner
        verdict = disjoint?(owner, mixins, types)
        @judging.pop
        verdict
      end

      private def disjoint?(
        owner : Index::Identity,
        mixins : Array(Index::Mixin),
        types : Types,
      ) : Bool
        paths = Hash(Index::Identity, Array(String)).new
        mixins.each do |mixin|
          parent = resolve_parent(mixin.target, owner, mixin.path, types)
          return false if parent.is_a?(Unknown)

          (paths[parent.identity] ||= Array(String).new) << mixin.path
        end

        vocabularies = Hash(Index::Identity, Set(String)).new
        paths.each_key do |module_name|
          vocabulary = vocabulary_of(module_name, owner, types)
          return false if vocabulary.is_a?(Unknown)

          vocabularies[module_name] = vocabulary
        end

        names = paths.keys
        names.each_with_index do |first, index|
          names[(index + 1)..].each do |second|
            next if single_file?(paths[first], paths[second])
            return false if vocabularies[first].intersects?(vocabularies[second])
          end
        end
        true
      end

      private def single_file?(first : Array(String), second : Array(String)) : Bool
        files = (first + second).uniq!
        files.size == 1
      end

      private def vocabulary_of(
        module_name : Index::Identity,
        owner : Index::Identity,
        types : Types,
      ) : Set(String) | Unknown
        chain = compute(module_name, types, [owner])
        return chain if chain.is_a?(Unknown)

        names = Set(String).new
        ([module_name] + chain).each do |level|
          return Unknown.new(:ambiguous, "#{level} may generate names") if generative?(level)

          @workspace.member_names(level).each { |name| names << name }
          extended = extended_names(level, types)
          return extended if extended.is_a?(Unknown)

          names.concat(extended)
        end
        names
      end

      private def extended_names(level : Index::Identity, types : Types) : Set(String) | Unknown
        names = Set(String).new
        @workspace.mixins_of(level).each do |mixin|
          next unless mixin.kind.extend?

          parent = resolve_parent(mixin.target, level, mixin.path, types)
          return parent if parent.is_a?(Unknown)
          next if parent.identity == level

          if generative?(parent.identity)
            return Unknown.new(:ambiguous, "#{parent.identity} may generate names")
          end

          @workspace.member_names(parent.identity).each { |name| names << name }
        end
        names
      end

      private def generative?(level : Index::Identity) : Bool
        return true if @workspace.opaque?(level)

        names = @workspace.member_names(level)
        Index::MacroHook.values.any? { |hook| names.includes?(hook.macro_name) }
      end

      private def builtin_parents(identity : Index::Identity) : Array(Parent) | Unknown
        unresolved = Unknown.new(:unresolved_name, identity.name)
        builtin(identity, unresolved) do |name|
          next unresolved unless Builtins.includes?(name)

          case (superclass = Builtins.superclass(name))
          in Builtins::NoSuperclass then Array(Parent).new
          in String
            [Parent.new(Index::Public.new(superclass), Array(Syntax::Type).new, nil)] of Parent
          end
        end
      end

      private def superclass(
        entries : Array(Index::Namespace),
        identity : Index::Identity,
        types : Types,
      ) : Parent | Builtins::NoSuperclass | Unknown
        entries.each do |entry|
          case entry
          in Index::ClassNamespace
            stated = entry.superclass
            next if stated.is_a?(Index::Unrestricted)
            return resolve_parent(stated, identity, entry.path, types)
          in Index::EnumNamespace
            return Parent.new(CoreType::Enum.identity, Array(Syntax::Type).new, nil)
          in Index::ModuleNamespace, Index::LibNamespace, Index::AnnotationNamespace
            return Builtins::NoSuperclass.new
          end
        end

        implicit_superclass(entries[0])
      end

      private def implicit_superclass(entry : Index::Namespace) : Parent | Builtins::NoSuperclass
        return Builtins::NoSuperclass.new unless entry.is_a?(Index::ClassNamespace)

        name = builtin(entry.identity, nil) do |declared|
          Builtins.superclass(declared) if Builtins.includes?(declared)
        end
        name ||= (entry.kind.struct? ? CoreType::Struct : CoreType::Reference).type_name
        return name if name.is_a?(Builtins::NoSuperclass)

        Parent.new(Index::Public.new(name), Array(Syntax::Type).new, nil)
      end

      private def resolve_parent(
        target : Syntax::TypeReader::Outcome,
        owner : Index::Identity,
        path : String,
        types : Types,
      ) : Parent | Unknown
        if target.is_a?(Syntax::TypeReader::Unsupported)
          return Unknown.new(:unsupported, target.source)
        end

        resolved = types.resolve_lexically(target, Scope.new(owner, type_vars_of(owner)).at(path))
        case resolved
        in TypeRef then Parent.new(resolved.identity, generic_arguments(target), path)
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
