require "compiler/crystal/syntax"
require "../index/sites"
require "../index/workspace"
require "../resolve/receiver"
require "../resolve/types"
require "../resolve/scope"
require "../core_type"
require "./branch_types"
require "./environment"
require "./inspection"
require "./finding"
require "./settled"

module Heucristic
  module Check
    struct Cases
      include Inspection

      KEYWORD = "case"

      @workspace : Index::Workspace
      @types : Resolve::Types
      @receiver : Resolve::Receiver
      @settled : Settled

      def initialize(environment : Environment) : Nil
        @workspace = environment.workspace
        @types = environment.types
        @receiver = environment.receiver
        @settled = environment.settled
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

        span = text.span_at(location, KEYWORD.size)
        return unless span

        resolved = @receiver.typed(subject, site.context)
        case resolved
        in Resolve::TypeRef
          return enum_case(node, resolved, site.context, span, findings) unless resolved.is?(:bool)

          bool_case(node, subject, site.context, span, findings)
        in Resolve::UnionRef
          union_case(node, subject, resolved, site.context, span, findings)
        in Resolve::MetaRef, Resolve::TypeVar, Resolve::Unknown then nil
        end
      end

      private def enum_case(
        node : Crystal::Case,
        resolved : Resolve::TypeRef,
        context : Syntax::Context,
        span : Document::Span,
        findings : Array(Finding),
      ) : Nil
        return unless resolved.arguments.empty?
        namespaces = @workspace.namespaces(resolved.identity)
        return unless namespaces.all?(Index::EnumNamespace)
        return if namespaces.any? { |entry| entry.is_a?(Index::EnumNamespace) && entry.flags }
        return unless @settled.type?(resolved.identity)

        members = @workspace.constants_of(resolved.identity).map do |constant|
          constant.name.rpartition("::")[2]
        end
        return if members.empty?

        scope = Resolve::Scope.of(context)
        covered = covered_members(node, resolved.identity, members, scope)
        return unless covered

        missing = members.reject { |member| covered.includes?(member) }
        return if missing.empty?

        message = String.build do |io|
          io << "case is not exhaustive for enum " << resolved.identity << ".\n\nMissing members:"
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

        branch_types = BranchTypes.new(@types, Resolve::Scope.of(context))
        covered = Array(Index::Identity).new
        node.whens.each do |branch|
          branch.conds.each do |cond|
            covering = branch_types.named_by(cond)
            return unless covering

            members.each do |member|
              covered << member.identity if branch_types.covers?(covering, member.identity)
            end
          end
        end
        missing = members.reject { |member| covered.includes?(member.identity) }.map(&.to_s)
        report_missing(missing, span, findings)
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
        enum_name : Index::Identity,
        members : Array(String),
        scope : Resolve::Scope,
      ) : Array(String)?
        covered = Array(String).new
        node.whens.each do |branch|
          branch.conds.each do |cond|
            next if foreign_member?(cond, enum_name, scope)

            member = member_named(cond, enum_name, members, scope)
            return unless member

            covered << member
          end
        end
        covered
      end

      private def member_named(
        cond : Crystal::ASTNode,
        enum_name : Index::Identity,
        members : Array(String),
        scope : Resolve::Scope,
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

          return last if cond.names.size == 1

          enum_of(cond, scope) == enum_name ? last : nil
        in Crystal::ASTNode then nil
        end
      end

      private def foreign_member?(
        cond : Crystal::ASTNode,
        enum_name : Index::Identity,
        scope : Resolve::Scope,
      ) : Bool
        return false unless cond.is_a?(Crystal::Path) && cond.names.size > 1

        located = enum_of(cond, scope)
        return false unless located.is_a?(Index::Identity) && located != enum_name

        namespaces = @workspace.namespaces(located)
        !namespaces.empty? && namespaces.all?(Index::EnumNamespace)
      end

      private def enum_of(
        cond : Crystal::Path,
        scope : Resolve::Scope,
      ) : Index::Identity | Resolve::Unknown
        @types.locate_any(Syntax::Named.new(cond.names[0...-1], cond.global?), scope)
      end
    end
  end
end
