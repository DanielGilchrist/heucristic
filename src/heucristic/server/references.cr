require "lsprotocol"
require "../index/workspace"
require "../index/entry"
require "../resolve/types"
require "../resolve/methods"
require "../resolve/receiver"
require "../syntax/target"
require "../syntax/variable_uses"
require "../syntax/instance_var_uses"
require "./uri"

module Heucristic
  module Server
    class References
      def initialize(
        @workspace : Index::Workspace,
        @types : Resolve::Types,
        @methods : Resolve::Methods,
        @receiver : Resolve::Receiver,
      ) : Nil
      end

      def of_entries(entries : Array(Index::Entry)) : Array(LSProtocol::Location)
        found = of_defs(entries.select(Index::Def))
        found.concat(of_names(entries))
        variables = entries.select(Index::InstanceVar).map { |entry| {entry.name, entry.owner} }
        variables.uniq!.each { |name, owner| found.concat(of_instance_var(name, owner)) }
        found
      end

      def of_defs(entries : Array(Index::Def)) : Array(LSProtocol::Location)
        found = Array(LSProtocol::Location).new
        entries.map(&.name).uniq!.each do |name|
          @workspace.call_uses(name).each do |use|
            next unless resolves_to?(use, entries)

            add(found, use.sites, use.call.name_location, name.size)
          end
        end
        found
      end

      def of_names(entries : Array(Index::Entry)) : Array(LSProtocol::Location)
        found = Array(LSProtocol::Location).new
        qualified = entries.compact_map { |entry| qualified_name(entry) }.uniq!
        qualified.each do |name|
          last = name.rpartition("::")[2]
          @workspace.path_uses(last).each do |use|
            next unless names?(use, name)

            add(found, use.sites, use.path.location, use.path.to_s.size)
          end
        end
        found
      end

      def of_variable(
        name : String,
        context : Syntax::Context,
        tree : Crystal::ASTNode,
        uri : String,
        text : Document::Text,
      ) : Array(LSProtocol::Location)
        definition = context.def_node
        body = definition ? definition.body : tree
        found = Array(LSProtocol::Location).new
        Syntax::VariableUses.of(body, name).each do |location|
          start = Document::Point.from(location)
          span = text.span(start, start.advance(name.size))
          next unless span.is_a?(Document::Span)

          found << LSProtocol::Location.new(range: span.to_range, uri: URI.parse(uri))
        end
        found
      end

      def of_instance_var(name : String, owner : String) : Array(LSProtocol::Location)
        found = Array(LSProtocol::Location).new
        @workspace.each_sites do |sites|
          Syntax::InstanceVarUses.of(sites.tree, sites.path, name, owner).each do |location|
            add(found, sites, location, name.size)
          end
        end
        found
      end

      private def resolves_to?(use : Index::CallUse, entries : Array(Index::Def)) : Bool
        receiver = @receiver.of_call(use.call, use.context)
        return false if receiver.is_a?(Resolve::Unknown)

        shape = @receiver.shape_of(use.call, use.context)
        @methods.lookup(receiver, shape).any? do |candidate|
          entries.any? do |entry|
            entry.path == candidate.path && entry.name_span == candidate.name_span
          end
        end
      end

      private def names?(use : Index::PathUse, qualified : String) : Bool
        scope = Resolve::Scope.new(
          use.context.owner, use.context.type_vars, Array(Resolve::Binding).new, use.context.path
        )
        located = @types.locate_any(Syntax::Named.new(use.path.names, use.path.global?), scope)
        located == qualified
      end

      private def qualified_name(entry : Index::Entry) : String?
        case entry
        in Index::Namespace, Index::Alias, Index::Constant then entry.name
        in Index::Def, Index::InstanceVar                  then nil
        end
      end

      private def add(
        found : Array(LSProtocol::Location),
        sites : Index::Sites,
        location : Crystal::Location?,
        size : Int32,
      ) : Nil
        return unless location

        start = Document::Point.from(location)
        span = sites.text.span(start, start.advance(size))
        return unless span.is_a?(Document::Span)

        uri = URI.parse(Uri.from_path(sites.path))
        found << LSProtocol::Location.new(range: span.to_range, uri: uri)
      end
    end
  end
end
