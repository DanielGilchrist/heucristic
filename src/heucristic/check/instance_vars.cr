require "compiler/crystal/syntax"
require "../index/sites"
require "../index/workspace"
require "../resolve/types"
require "../resolve/methods"
require "../resolve/receiver"
require "../resolve/scope"
require "../syntax/well_known"
require "./finding"
require "./settled"
require "./macro_arguments"
require "./assigned_instance_vars"
require "./fit"

module Heucristic
  module Check
    struct InstanceVars
      def initialize(
        @workspace : Index::Workspace,
        @types : Resolve::Types,
        @methods : Resolve::Methods,
        @receiver : Resolve::Receiver,
        @settled : Settled,
      ) : Nil
      end

      def run(sites : Index::Sites, findings : Array(Finding)) : Nil
        sites.instance_vars.each { |site| check(site, sites.text, findings) }
        sites.defs.each { |site| initializer(site, sites.text, findings) }
      end

      private def check(
        site : Syntax::Uses::InstanceVarSite,
        text : Document::Text,
        findings : Array(Finding),
      ) : Nil
        owner = site.context.owner
        return unless owner.is_a?(String)
        return unless closed?(owner)
        return if MacroArguments.within?(site.context.ancestors, @workspace)
        location = site.node.location
        return unless location

        start = Document::Point.from(location)
        span = text.span(start, start.advance(site.node.name.size))
        return unless span.is_a?(Document::Span)

        entries = @methods.levels(owner).flat_map do |level|
          @workspace.instance_vars_of(level).select(&.name.==(site.node.name))
        end
        if entries.empty?
          return if site.assign

          message = "can't infer the type of instance variable '#{site.node.name}' of #{owner}"
          findings << Finding.new(:unknown_instance_var, message, span)
          return
        end

        assign = site.assign
        return unless assign

        declared = entries.select(&.origin.declared?)
        return if declared.empty?

        expected = declared_type(declared, owner)
        return unless expected
        fit = Fit.new(@methods)
        return if assign.value.is_a?(Crystal::NumberLiteral) && fit.numeric?(expected)

        actual = @receiver.typed(assign.value, site.context.inside(assign.value))
        return if actual.is_a?(Resolve::Unknown)
        return if fit.fits?(expected, actual, Resolve::Precision.of(assign.value))

        message = String.build do |io|
          io << "instance variable '" << site.node.name << "' of " << declared[0].owner
          io << " must be " << expected << ", not " << actual
        end
        findings << Finding.new(:instance_var_mismatch, message, span)
      end

      private def initializer(
        site : Syntax::Uses::DefSite,
        text : Document::Text,
        findings : Array(Finding),
      ) : Nil
        node = site.node
        return unless Syntax::WellKnown::Initialize.named?(node.name) && node.receiver.nil?
        owner = site.context.owner
        return unless owner.is_a?(String)
        return unless closed?(owner)
        return if @workspace.namespaces(owner).any?(Index::ModuleNamespace)
        location = node.name_location
        return unless location

        assigned = AssignedInstanceVars.of(node.body, @workspace)
        return if assigned.is_a?(AssignedInstanceVars::Undecidable)

        declared = @workspace.instance_vars_of(owner)
        declared.each do |entry|
          next unless entry.origin.declared?
          next if entry.initialized || entry.in_def
          next if assigned.includes?(entry.name)
          next if nilable?(entry, owner)
          next if declared.any? { |other| other.name == entry.name && other.initialized }

          start = Document::Point.from(location)
          span = text.span(start, start.advance(node.name.size))
          return unless span.is_a?(Document::Span)

          message = String.build do |io|
            io << "this 'initialize' doesn't explicitly initialize instance variable '"
            io << entry.name << "' of " << owner << ", rendering it nilable"
          end
          findings << Finding.new(:uninitialized_instance_var, message, span)
        end
      end

      private def closed?(owner : String) : Bool
        (@settled.type?(owner) || @settled.declared?(owner)) &&
          !@settled.extended?(owner) && @settled.generated_free?(owner)
      end

      private def declared_type(
        declared : Array(Index::InstanceVar),
        owner : String,
      ) : Resolve::Resolution?
        entry = declared[0]
        type = entry.type
        return unless type.is_a?(Syntax::Type)

        scope = Resolve::Scope.new(entry.owner, @types.type_vars_of(entry.owner))
        resolved = @types.resolve_lexically(type, scope)
        Fit.new(@methods).checkable?(resolved) ? resolved : nil
      end

      private def nilable?(entry : Index::InstanceVar, owner : String) : Bool
        type = entry.type
        return true unless type.is_a?(Syntax::Type)
        return true if type.is_a?(Syntax::Nilable)

        scope = Resolve::Scope.new(owner, @types.type_vars_of(owner))
        Fit.new(@methods).nilable?(@types.resolve_lexically(type, scope))
      end
    end
  end
end
