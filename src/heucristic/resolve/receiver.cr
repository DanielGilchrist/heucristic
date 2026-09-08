require "compiler/crystal/syntax"
require "../index/workspace"
require "../index/evident"
require "../syntax/target"
require "../syntax/type_reader"
require "./types"
require "./local_declarations"
require "./local_assignments"

module Heucristic
  module Resolve
    class Receiver
      def initialize(@workspace : Index::Workspace, @types : Types) : Nil
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
        when Crystal::Call
          Unknown.new(:inference_needed, "the result of `#{node.name}` needs type inference")
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
