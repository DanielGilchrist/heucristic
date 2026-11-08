require "compiler/crystal/syntax"
require "../index/sites"
require "../index/workspace"
require "../resolve/types"
require "../resolve/scope"
require "../syntax/type_reader"
require "./environment"
require "./inspection"
require "./finding"
require "./settled"

module Heucristic
  module Check
    struct Generics
      include Inspection

      @workspace : Index::Workspace
      @types : Resolve::Types
      @settled : Settled
      @root : String

      def initialize(environment : Environment) : Nil
        @workspace = environment.workspace
        @types = environment.types
        @settled = environment.settled
        @root = environment.root
      end

      def run(sites : Index::Sites, findings : Array(Finding)) : Nil
        sites.generics.each { |site| check(site, sites.text, findings) }
      end

      private def check(
        site : Syntax::Uses::GenericSite,
        text : Document::Text,
        findings : Array(Finding),
      ) : Nil
        node = site.node
        name = node.name
        location = node.location
        return unless name.is_a?(Crystal::Path) && location
        return if node.named_args
        return unless node.type_vars.none?(Crystal::Splat)

        scope = Resolve::Scope.of(site.context)
        located = @types.locate(Syntax::Named.new(name.names, name.global?), scope)
        return if located.is_a?(Resolve::Unknown)
        return unless @workspace.aliases(name.names.last).empty?
        return unless @settled.type?(located) || stdlib?(located)
        return if @types.splat_index_of(located)

        expected = @types.type_vars_of(located)
        given = node.type_vars.size
        return if expected.size == given

        span = text.span_at(location, name.to_s.size)
        return unless span

        if expected.empty?
          message = "#{located} is not a generic type, it's a #{kind(located)}"
          findings << Finding.new(:not_generic, message, span)
          return
        end

        message = String.build do |io|
          io << "wrong number of type vars for " << located << '('
          expected.join(io, ", ")
          io << ") (given " << given << ", expected " << expected.size << ')'
        end
        findings << Finding.new(:wrong_type_arguments, message, span)
      end

      private def stdlib?(name : String) : Bool
        entries = @workspace.namespaces(name)
        !entries.empty? && entries.none?(&.path.starts_with?(@root + "/"))
      end

      private def kind(name : String) : String
        entry = @workspace.namespaces(name).first
        case entry
        in Index::ClassNamespace      then entry.kind.struct? ? "struct" : "class"
        in Index::ModuleNamespace     then "module"
        in Index::EnumNamespace       then "enum"
        in Index::LibNamespace        then "lib"
        in Index::AnnotationNamespace then "annotation"
        end
      end
    end
  end
end
