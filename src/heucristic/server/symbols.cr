require "lsprotocol"
require "../index/workspace"
require "../index/entry"
require "./uri"

require "../syntax/well_known"

module Heucristic
  module Server
    class Symbols
      LIMIT      = 200
      TYPE_KINDS = {
        LSProtocol::SymbolKind::Class,
        LSProtocol::SymbolKind::Struct,
        LSProtocol::SymbolKind::Module,
        LSProtocol::SymbolKind::Enum,
      }

      def initialize(@workspace : Index::Workspace) : Nil
      end

      def in_document(path : String) : Array(LSProtocol::DocumentSymbol)
        file = @workspace.file(path)
        return Array(LSProtocol::DocumentSymbol).new unless file

        containers = Hash(Index::Owner, Array(LSProtocol::DocumentSymbol)).new
        roots = Array(LSProtocol::DocumentSymbol).new
        file.namespaces.each do |entry|
          children = Array(LSProtocol::DocumentSymbol).new
          containers[entry.identity] = children
        end
        file.namespaces.each do |entry|
          children = containers[entry.identity]
          symbol = document_symbol(label(entry), kind_of(entry), entry.name_span, children)
          place(entry.identity.parent, symbol, containers, roots)
        end
        members(file).each do |owner, entry|
          symbol = document_symbol(label(entry), kind_of(entry), entry.name_span, nil)
          place(owner, symbol, containers, roots)
        end
        roots
      end

      def matching(query : String, root : String) : Array(LSProtocol::SymbolInformation)
        needle = query.downcase
        found = Array(LSProtocol::SymbolInformation).new
        reopenings = Hash(Index::Identity, Array(Index::Namespace)).new
        @workspace.each_file do |file|
          next unless project?(file.path, root)

          file.namespaces.each do |entry|
            (reopenings[entry.identity] ||= Array(Index::Namespace).new) << entry
          end
          file.defs.each do |entry|
            consider(found, entry, entry.name, needle, container(entry.owner))
          end
          file.constants.each { |entry| consider(found, entry, entry.name, needle, nil) }
          file.aliases.each { |entry| consider(found, entry, entry.name, needle, nil) }
        end
        reopenings.each do |identity, entries|
          consider(found, primary(identity, entries), identity.name, needle, nil)
        end
        found.sort_by! do |symbol|
          prefix = symbol.name.downcase.starts_with?(needle) ? 0 : 1
          {prefix, TYPE_KINDS.includes?(symbol.kind) ? 0 : 1, symbol.name.size}
        end
        found.first(LIMIT)
      end

      private def primary(
        identity : Index::Identity,
        entries : Array(Index::Namespace),
      ) : Index::Namespace
        return entries[0] if entries.size == 1

        basename = identity.last.underscore
        named = entries.find { |entry| ::File.basename(entry.path, ".cr") == basename }
        return named if named

        entries.max_by { |entry| members_in(entry) }
      end

      private def members_in(entry : Index::Namespace) : Int32
        file = @workspace.file(entry.path)
        return 0 unless file

        file.defs.count(&.owner.==(entry.name)) + file.namespaces.count do |nested|
          nested.name.starts_with?("#{entry.name}::")
        end
      end

      private def project?(path : String, root : String) : Bool
        return false unless path.starts_with?(root)

        {"lib", ".shards"}.none? { |vendored| path.starts_with?(::File.join(root, vendored)) }
      end

      private def consider(
        found : Array(LSProtocol::SymbolInformation),
        entry : Index::Entry,
        name : String,
        needle : String,
        container : String?,
      ) : Nil
        return unless matches?(name, needle)

        location = LSProtocol::Location.new(
          range: entry.name_span.to_range, uri: URI.parse(Uri.from_path(entry.path))
        )
        found << LSProtocol::SymbolInformation.new(
          name: name, kind: kind_of(entry), location: location, container_name: container
        )
      end

      private def matches?(name : String, needle : String) : Bool
        return true if needle.empty?

        haystack = name.downcase
        position = 0
        needle.each_char do |char|
          index = haystack.index(char, position)
          return false unless index

          position = index + 1
        end
        true
      end

      private def members(file : Index::File) : Array({Index::Owner, Index::Entry})
        found = Array({Index::Owner, Index::Entry}).new
        file.defs.each { |entry| found << {entry.owner, entry} }
        file.constants.each { |entry| found << {entry.identity.parent, entry} }
        seen = Set(String).new
        file.instance_vars.each do |entry|
          found << {entry.owner, entry} if seen.add?("#{entry.owner}#{entry.name}")
        end
        file.aliases.each { |entry| found << {entry.identity.parent, entry} }
        found
      end

      private def place(
        owner : Index::Owner,
        symbol : LSProtocol::DocumentSymbol,
        containers : Hash(Index::Owner, Array(LSProtocol::DocumentSymbol)),
        roots : Array(LSProtocol::DocumentSymbol),
      ) : Nil
        (containers[owner]? || roots) << symbol
      end

      private def document_symbol(
        name : String,
        kind : LSProtocol::SymbolKind,
        span : Document::Span,
        children : Array(LSProtocol::DocumentSymbol)?,
      ) : LSProtocol::DocumentSymbol
        LSProtocol::DocumentSymbol.new(
          name: name,
          kind: kind,
          range: span.to_range,
          selection_range: span.to_range,
          children: children,
        )
      end

      private def label(entry : Index::Entry) : String
        case entry
        in Index::Def then entry.receiver.metaclass? ? "self.#{entry.name}" : entry.name
        in Index::Constant, Index::Alias, Index::Namespace
          entry.identity.last
        in Index::InstanceVar then entry.name
        end
      end

      private def container(owner : Index::Owner) : String?
        owner.is_a?(Index::Identity) ? owner.name : nil
      end

      private def kind_of(entry : Index::Entry) : LSProtocol::SymbolKind
        case entry
        in Index::Def
          constructor = Syntax::WellKnown::Initialize.named?(entry.name)
          constructor ? LSProtocol::SymbolKind::Constructor : LSProtocol::SymbolKind::Method
        in Index::ClassNamespace
          entry.kind.struct? ? LSProtocol::SymbolKind::Struct : LSProtocol::SymbolKind::Class
        in Index::ModuleNamespace, Index::LibNamespace then LSProtocol::SymbolKind::Module
        in Index::EnumNamespace                        then LSProtocol::SymbolKind::Enum
        in Index::AnnotationNamespace                  then LSProtocol::SymbolKind::Interface
        in Index::Alias                                then LSProtocol::SymbolKind::TypeParameter
        in Index::InstanceVar                          then LSProtocol::SymbolKind::Field
        in Index::Constant                             then LSProtocol::SymbolKind::Constant
        end
      end
    end
  end
end
