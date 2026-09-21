require "compiler/crystal/syntax"
require "../index/sites"
require "../index/workspace"
require "../resolve/receiver"
require "../resolve/types"
require "../resolve/scope"
require "../syntax/type_reader"
require "../core_type"
require "./finding"
require "./settled"

module Heucristic
  module Check
    struct Cases
      KEYWORD = "case"

      def initialize(
        @workspace : Index::Workspace,
        @types : Resolve::Types,
        @receiver : Resolve::Receiver,
        @settled : Settled,
      ) : Nil
      end

      def run(sites : Index::Sites, findings : Array(Finding)) : Nil
        sites.cases.each { |site| check(site, sites.text, findings) }
      end

      private def check(
        site : Syntax::Uses::CaseSite,
        text : Document::Text,
        findings : Array(Finding),
      ) : Nil
        node = site.node
        subject = node.cond
        location = node.location
        return unless subject && location && node.else.nil?

        start = Document::Point.from(location)
        span = text.span(start, start.advance(KEYWORD.size))
        return unless span.is_a?(Document::Span)

        resolved = @receiver.typed(subject, site.context)
        case resolved
        in Resolve::TypeRef
          return enum_case(node, resolved, span, findings) unless resolved.is?(:bool)

          bool_case(node, subject, site.context, span, findings)
        in Resolve::UnionRef
          union_case(node, subject, resolved, site.context, span, findings)
        in Resolve::MetaRef, Resolve::TypeVar, Resolve::Unknown then nil
        end
      end

      private def enum_case(
        node : Crystal::Case,
        resolved : Resolve::TypeRef,
        span : Document::Span,
        findings : Array(Finding),
      ) : Nil
        return unless resolved.arguments.empty?
        namespaces = @workspace.namespaces(resolved.name)
        return unless namespaces.all?(Index::EnumNamespace)
        return if namespaces.any? { |entry| entry.is_a?(Index::EnumNamespace) && entry.flags }
        return unless @settled.type?(resolved.name)

        members = @workspace.constants_of(resolved.name).map do |constant|
          constant.name.rpartition("::")[2]
        end
        return if members.empty?

        covered = covered_members(node, resolved.name, members)
        return unless covered

        missing = members.reject { |member| covered.includes?(member) }
        return if missing.empty?

        message = String.build do |io|
          io << "case is not exhaustive for enum " << resolved.name << ".\n\nMissing members:"
          missing.each { |member| io << "\n - " << member }
        end
        findings << Finding.new(:non_exhaustive_case, message, span)
      end

      private def bool_case(
        node : Crystal::Case,
        subject : Crystal::ASTNode,
        context : Syntax::Context,
        span : Document::Span,
        findings : Array(Finding),
      ) : Nil
        return unless plain_parameter?(subject, context)

        covered = Array(String).new
        node.whens.each do |branch|
          branch.conds.each do |cond|
            case cond
            in Crystal::BoolLiteral then covered << cond.value.to_s
            in Crystal::Path        then return unless bool_path?(cond, covered)
            in Crystal::ASTNode     then return
            end
          end
        end
        missing = ["true", "false"].reject { |value| covered.includes?(value) }
        report_missing(missing, span, findings)
      end

      private def bool_path?(cond : Crystal::Path, covered : Array(String)) : Bool
        return false unless cond.names == [CoreType::Bool.type_name]

        covered << "true" << "false"
        true
      end

      private def union_case(
        node : Crystal::Case,
        subject : Crystal::ASTNode,
        resolved : Resolve::UnionRef,
        context : Syntax::Context,
        span : Document::Span,
        findings : Array(Finding),
      ) : Nil
        return unless plain_parameter?(subject, context)
        members = resolved.members.map do |member|
          return unless member.is_a?(Resolve::TypeRef)

          member
        end

        scope = Resolve::Scope.new(context.owner, context.type_vars)
        covered = Array(String).new
        node.whens.each do |branch|
          branch.conds.each do |cond|
            covering = covering_type(cond, scope)
            return unless covering

            members.each { |member| covered << member.name if covers?(covering, member.name) }
          end
        end
        missing = members.reject { |member| covered.includes?(member.name) }.map(&.to_s)
        report_missing(missing, span, findings)
      end

      private def covering_type(cond : Crystal::ASTNode, scope : Resolve::Scope) : String?
        return CoreType::Nil.type_name if cond.is_a?(Crystal::NilLiteral)
        return unless cond.is_a?(Crystal::Path | Crystal::Generic)

        read = Syntax::TypeReader.read(cond)
        return unless read.is_a?(Syntax::Type)

        resolved = @types.resolve_lexically(read, scope)
        resolved.is_a?(Resolve::TypeRef) ? resolved.name : nil
      end

      private def covers?(covering : String, member : String) : Bool
        return true if covering == member

        chain = @types.ancestors(member)
        !chain.is_a?(Resolve::Unknown) && chain.includes?(covering)
      end

      private def plain_parameter?(subject : Crystal::ASTNode, context : Syntax::Context) : Bool
        return false unless subject.is_a?(Crystal::Var)
        definition = context.def_node
        return false unless definition
        declared = definition.args.any? { |arg| arg.name == subject.name && arg.restriction }
        return false unless declared

        @receiver.narrowing_steps(subject.name, context).empty?
      end

      private def report_missing(
        missing : Array(String),
        span : Document::Span,
        findings : Array(Finding),
      ) : Nil
        return if missing.empty?

        message = String.build do |io|
          io << "case is not exhaustive.\n\nMissing cases:"
          missing.each { |value| io << "\n - " << value }
        end
        findings << Finding.new(:non_exhaustive_case, message, span)
      end

      private def covered_members(
        node : Crystal::Case,
        enum_name : String,
        members : Array(String),
      ) : Array(String)?
        covered = Array(String).new
        node.whens.each do |branch|
          branch.conds.each do |cond|
            member = member_named(cond, enum_name, members)
            return unless member

            covered << member
          end
        end
        covered
      end

      private def member_named(
        cond : Crystal::ASTNode,
        enum_name : String,
        members : Array(String),
      ) : String?
        case cond
        in Crystal::Call
          return unless cond.obj.is_a?(Crystal::ImplicitObj) && cond.args.empty?
          return unless cond.name.ends_with?('?')

          predicate = cond.name.rchop('?')
          members.find { |member| member.underscore == predicate }
        in Crystal::Path
          last = cond.names.last
          return unless members.includes?(last)

          prefix = cond.names[0...-1].join("::")
          prefix.empty? || enum_name.ends_with?(prefix) ? last : nil
        in Crystal::ASTNode then nil
        end
      end
    end
  end
end
