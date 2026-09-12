require "compiler/crystal/syntax"
require "../index/sites"
require "../index/workspace"
require "../resolve/receiver"
require "./finding"
require "./settled"

module Heucristic
  module Check
    struct Cases
      KEYWORD = "case"

      def initialize(
        @workspace : Index::Workspace,
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

        resolved = @receiver.typed(subject, site.context)
        return unless resolved.is_a?(Resolve::TypeRef) && resolved.arguments.empty?
        return unless @workspace.namespaces(resolved.name).all?(Index::EnumNamespace)
        return unless @settled.type?(resolved.name)

        members = @workspace.constants_of(resolved.name).map do |constant|
          constant.name.rpartition("::")[2]
        end
        return if members.empty?

        covered = covered_members(node, resolved.name, members)
        return unless covered

        missing = members.reject { |member| covered.includes?(member) }
        return if missing.empty?

        start = Document::Point.from(location)
        span = text.span(start, start.advance(KEYWORD.size))
        return unless span.is_a?(Document::Span)

        message = String.build do |io|
          io << "case is not exhaustive for enum " << resolved.name << ".\n\nMissing members:"
          missing.each { |member| io << "\n - " << member }
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
