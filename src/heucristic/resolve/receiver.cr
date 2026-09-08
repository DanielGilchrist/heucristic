require "compiler/crystal/syntax"
require "../index/workspace"
require "../index/evident"
require "../syntax/target"
require "../syntax/type_reader"
require "./types"
require "./methods"
require "./local_declarations"
require "./local_assignments"

module Heucristic
  module Resolve
    class Receiver
      def initialize(@workspace : Index::Workspace, @types : Types, @methods : Methods) : Nil
      end

      def result_of(call : Crystal::Call, context : Syntax::Context) : Resolution
        receiver = of_call(call, context)
        return receiver if receiver.is_a?(Unknown)

        result_of(receiver, call.name, call.args.size)
      end

      def result_of(receiver : Resolved, name : String, arity : Int32) : Resolution
        if receiver.is_a?(UnionRef)
          members = receiver.members.map do |member|
            member.is_a?(Unknown) ? member : result_of(member, name, arity)
          end
          return union(members)
        end

        defs = @methods.lookup(receiver, name, arity)
        return Unknown.new(:unresolved_name, "no `#{name}` on #{receiver}") if defs.empty?

        results = defs.map { |entry| return_type(entry, receiver) }
        resolved = results.select(Resolved).uniq!
        return resolved[0] if resolved.size == 1
        return results[0] if resolved.empty?

        Unknown.new(:ambiguous, "#{defs.size} overloads of `#{name}` return different types")
      end

      def of_call(call : Crystal::Call, context : Syntax::Context) : Resolution
        receiver = call.obj
        return implicit_self(context) unless receiver

        type_of(receiver, context)
      end

      def type_of(node : Crystal::ASTNode, context : Syntax::Context) : Resolution
        type_of(node, context, Array(String).new)
      end

      def variable(name : String, context : Syntax::Context) : Resolution
        variable(name, context, Array(String).new)
      end

      def instance_var(name : String, context : Syntax::Context) : Resolution
        owner = context.owner
        if owner.is_a?(Index::TopLevel)
          return Unknown.new(:no_annotation, "#{name} outside any type")
        end

        entries = @workspace.instance_vars_of(owner).select(&.name.==(name))
        declared = entries.select(&.origin.declared?)
        sources = declared.empty? ? entries : declared
        if sources.empty?
          return Unknown.new(
            :no_annotation, "#{name} is never declared or assigned an evident type in #{owner}"
          )
        end

        scope = Scope.of(owner)
        union(sources.map { |entry| declared(entry.type, scope) })
      end

      private def type_of(
        node : Crystal::ASTNode,
        context : Syntax::Context,
        visiting : Array(String),
      ) : Resolution
        evident = Index::Evident.type(node)
        return declared(evident, scope(context)) if evident.is_a?(Syntax::Type)

        case node
        when Crystal::Var         then variable(node.name, context, visiting)
        when Crystal::InstanceVar then instance_var(node.name, context)
        when Crystal::Call        then result_of(node, context)
        else
          Unknown.new(:inference_needed, "the type of `#{node}` is not written in the source")
        end
      end

      private def variable(
        name : String,
        context : Syntax::Context,
        visiting : Array(String),
      ) : Resolution
        return implicit_self(context) if name == "self"

        definition = context.def_node
        return Unknown.new(:no_annotation, "#{name} is outside any method") unless definition

        if (parameter = definition.args.find(&.name.==(name)))
          restriction = parameter.restriction
          unless restriction
            return Unknown.new(:no_annotation, "parameter #{name} has no type restriction")
          end
          return declared(Syntax::TypeReader.read(restriction), scope(context))
        end

        if (declaration = LocalDeclarations.find(definition.body, name))
          return declared(Syntax::TypeReader.read(declaration.declared_type), scope(context))
        end

        return Unknown.new(:cycle, name) if visiting.includes?(name)

        assignments = LocalAssignments.find(definition.body, name)
        if assignments.empty?
          return Unknown.new(
            :no_annotation, "#{name} is not a parameter and is never assigned here"
          )
        end

        union(assignments.map { |value| type_of(value, context, visiting + [name]) })
      end

      private def union(resolutions : Array(Resolution)) : Resolution
        members = Array(Resolution).new
        resolutions.each do |resolution|
          return resolution if resolution.is_a?(Unknown)
          members << resolution unless members.includes?(resolution)
        end
        members.size == 1 ? members[0] : UnionRef.new(members)
      end

      private def implicit_self(context : Syntax::Context) : Resolution
        owner = context.owner
        return Unknown.new(:top_level, "no enclosing type") if owner.is_a?(Index::TopLevel)

        this = TypeRef.new(owner, Array(Resolution).new)
        definition = context.def_node
        definition && definition.receiver ? MetaRef.new(this) : this
      end

      def return_type(entry : Index::Def, receiver : Resolved) : Resolution
        if entry.name == "initialize" && receiver.is_a?(MetaRef)
          return receiver.of
        end

        case (restriction = entry.return_type)
        in Index::Unrestricted
          Unknown.new(:no_annotation, "#{entry.qualified} has no return type restriction")
        in Syntax::TypeReader::Unsupported
          Unknown.new(:unsupported, restriction.source)
        in Syntax::Type
          scope = return_scope(entry, receiver)
          return scope if scope.is_a?(Unknown)

          @types.resolve(restriction, scope)
        end
      end

      private def return_scope(entry : Index::Def, receiver : Resolved) : Scope | Unknown
        owner = entry.owner
        return Scope.new(owner, entry.free_vars) if owner.is_a?(Index::TopLevel)

        instance = receiver.is_a?(MetaRef) ? receiver.of : receiver
        bindings = instance.is_a?(TypeRef) ? @types.bindings(instance, owner) : Array(Binding).new
        return bindings if bindings.is_a?(Unknown)

        Scope.new(owner, @types.type_vars_of(owner) + entry.free_vars, bindings)
      end

      private def scope(context : Syntax::Context) : Scope
        Scope.new(context.owner, context.type_vars)
      end

      private def declared(type : Syntax::TypeReader::Outcome, scope : Scope) : Resolution
        return Unknown.new(:unsupported, type.source) if type.is_a?(Syntax::TypeReader::Unsupported)

        @types.resolve(type, scope)
      end
    end
  end
end
