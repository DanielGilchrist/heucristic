require "lsprotocol"
require "../document/text"
require "../index/workspace"
require "../index/collector"
require "../resolve/receiver"
require "../resolve/methods"
require "../resolve/types"
require "../syntax"
require "../syntax/cursor"
require "../syntax/defined_variables"
require "../requires"

module Heucristic
  module Server
    class Completion
      PLACEHOLDER      = "zzheucristic"
      PATH_PLACEHOLDER = "Zzheucristic"

      record Request,
        text : Document::Text,
        offset : Int32,
        path : String,
        source_paths : Array(String)

      alias Child = {String, LSProtocol::CompletionItemKind}

      REQUIRE_PREFIX = /\A\s*require\s+"([^"]*)\z/

      def initialize(
        @workspace : Index::Workspace,
        @types : Resolve::Types,
        @methods : Resolve::Methods,
        @receiver : Resolve::Receiver,
      ) : Nil
      end

      def complete(request : Request) : Array(LSProtocol::CompletionItem)
        source = request.text.source
        required = require_string(source, request.offset)
        return requires(request, required) if required

        start = word_start(source, request.offset)
        prefix = source.byte_slice(start, request.offset - start)
        before = start > 0 ? source.to_slice[start - 1].chr : ' '
        constant = before == ':' || prefix[0]?.try(&.uppercase?) || false
        placeholder = constant ? PATH_PLACEHOLDER : PLACEHOLDER
        probe = request.text.splice(start, request.offset, placeholder)
        tree = Syntax.parse(probe.source, request.path)
        return Array(LSProtocol::CompletionItem).new if tree.is_a?(Syntax::Broken)

        @workspace.update(Index::Collector.collect(
          request.path, probe, tree, @workspace.crystal_version
        ))
        @types.invalidate
        point = probe.point_at(start)
        return Array(LSProtocol::CompletionItem).new if point.is_a?(Document::OutOfRange)

        target = Syntax::Cursor.find(tree, point, request.path, @workspace.crystal_version)
        items = case target
                in Syntax::OnCall then calls(target, prefix)
                in Syntax::OnPath then paths(target, prefix)
                in Syntax::OnDef,
                   Syntax::OnVar,
                   Syntax::OnInstanceVar,
                   Syntax::OnName,
                   Syntax::OnRequire,
                   Nil
                  Array(LSProtocol::CompletionItem).new
                end
        items.uniq!(&.label)
        items.reject!(&.label.starts_with?("__"))
        ranked = Array(LSProtocol::CompletionItem).new(items.size)
        items.each_with_index do |item, index|
          ranked << LSProtocol::CompletionItem.new(
            label: item.label,
            kind: item.kind,
            detail: item.detail,
            insert_text: item.insert_text,
            insert_text_format: item.insert_text_format,
            text_edit: item.text_edit,
            sort_text: "#{item.label[0].alphanumeric? ? 0 : 1}#{index.to_s.rjust(5, '0')}",
          )
        end
        ranked
      end

      private def require_string(source : String, offset : Int32) : String?
        bytes = source.to_slice
        line_start = offset
        while line_start > 0 && bytes[line_start - 1] != '\n'.ord
          line_start -= 1
        end
        before = source.byte_slice(line_start, offset - line_start)
        before.match(REQUIRE_PREFIX).try(&.[1])
      end

      private def requires(request : Request, partial : String) : Array(LSProtocol::CompletionItem)
        tail = partial[(partial.rindex('/').try(&.+(1)) || 0)..]
        start = request.text.point_at(request.offset - tail.bytesize)
        finish = request.text.point_at(request.offset)
        items = Array(LSProtocol::CompletionItem).new
        return items if start.is_a?(Document::OutOfRange) || finish.is_a?(Document::OutOfRange)

        span = request.text.span(start, finish)
        return items unless span.is_a?(Document::Span)

        Requires.new(request.source_paths).candidates(partial, request.path).each do |candidate|
          text = candidate.directory ? "#{candidate.label}/" : candidate.label
          kind = if candidate.directory
                   LSProtocol::CompletionItemKind::Folder
                 else
                   LSProtocol::CompletionItemKind::File
                 end
          items << LSProtocol::CompletionItem.new(
            label: candidate.label,
            kind: kind,
            text_edit: LSProtocol::TextEdit.new(range: span.to_range, new_text: text),
          )
        end
        items
      end

      private def word_start(source : String, offset : Int32) : Int32
        bytes = source.to_slice
        start = offset
        while start > 0 && identifier?(bytes[start - 1])
          start -= 1
        end
        start
      end

      private def identifier?(byte : UInt8) : Bool
        char = byte.chr
        byte >= 0x80 || char.alphanumeric? || char == '_' || char == '?' || char == '!'
      end

      private def calls(
        target : Syntax::OnCall,
        prefix : String,
      ) : Array(LSProtocol::CompletionItem)
        call = target.node
        items = Array(LSProtocol::CompletionItem).new
        receiver = @receiver.of_call(call, target.context)
        if receiver.is_a?(Resolve::Resolved)
          @methods.candidates(receiver).each do |entry|
            items << method_item(entry) if entry.name.starts_with?(prefix)
          end
        end
        return items if call.obj

        variables(target.context).each do |name|
          next unless name.starts_with?(prefix)

          items << LSProtocol::CompletionItem.new(
            label: name, kind: LSProtocol::CompletionItemKind::Variable
          )
        end
        @workspace.defs_of(Index::TopLevel.new).each do |entry|
          items << method_item(entry) if entry.name.starts_with?(prefix)
        end
        items
      end

      private def variables(context : Syntax::Context) : Set(String)
        names = Set(String).new
        context.def_node.try { |definition| names.concat(Syntax::DefinedVariables.of(definition)) }
        context.blocks.each do |call|
          call.block.try &.args.each { |argument| names << argument.name }
        end
        names.delete(PLACEHOLDER)
        names
      end

      private def paths(
        target : Syntax::OnPath,
        prefix : String,
      ) : Array(LSProtocol::CompletionItem)
        names = target.node.names[0...-1]
        items = Array(LSProtocol::CompletionItem).new
        parents = if names.empty?
                    scope_chain(target.context)
                  else
                    named = Syntax::Named.new(names, target.node.global?)
                    located = @types.locate_any(named, Resolve::Scope.of(target.context))
                    owners = Array(Index::Owner).new
                    owners << located if located.is_a?(Index::Identity)
                    owners
                  end
        parents.each do |parent|
          children_of(parent).each do |name, kind|
            next unless name.starts_with?(prefix)

            items << LSProtocol::CompletionItem.new(label: name, kind: kind)
          end
        end
        items
      end

      private def scope_chain(context : Syntax::Context) : Array(Index::Owner)
        chain = Array(Index::Owner).new
        current = context.owner
        while current.is_a?(Index::Identity)
          chain << current
          current = current.parent
        end
        chain << Index::TopLevel.new
        chain
      end

      private def children_of(parent : Index::Owner) : Array(Child)
        found = Array(Child).new
        prefix = case parent
                 in Index::Identity then "#{parent.name}::"
                 in Index::TopLevel then ""
                 end
        @workspace.each_file do |file|
          file.namespaces.each do |entry|
            next unless direct_child?(entry.name, prefix)

            found << {entry.name.lchop(prefix), namespace_kind(entry)}
          end
          file.constants.each do |entry|
            next unless direct_child?(entry.name, prefix)

            found << {entry.name.lchop(prefix), LSProtocol::CompletionItemKind::Constant}
          end
          file.aliases.each do |entry|
            next unless direct_child?(entry.name, prefix)

            found << {entry.name.lchop(prefix), LSProtocol::CompletionItemKind::Class}
          end
        end
        found
      end

      private def direct_child?(name : String, prefix : String) : Bool
        return false unless name.starts_with?(prefix)

        rest = name.lchop(prefix)
        !rest.empty? && !rest.includes?("::")
      end

      private def namespace_kind(entry : Index::Namespace) : LSProtocol::CompletionItemKind
        case entry
        in Index::ClassNamespace
          return LSProtocol::CompletionItemKind::Struct if entry.kind.struct?

          LSProtocol::CompletionItemKind::Class
        in Index::ModuleNamespace, Index::LibNamespace
          LSProtocol::CompletionItemKind::Module
        in Index::EnumNamespace
          LSProtocol::CompletionItemKind::Enum
        in Index::AnnotationNamespace
          LSProtocol::CompletionItemKind::Interface
        end
      end

      private def method_item(entry : Index::Def) : LSProtocol::CompletionItem
        required = entry.parameters.select do |parameter|
          parameter.kind.positional? && parameter.default.nil?
        end
        if required.empty?
          return LSProtocol::CompletionItem.new(
            label: entry.name,
            kind: LSProtocol::CompletionItemKind::Property,
            detail: entry.signature,
            insert_text: entry.name,
            insert_text_format: LSProtocol::InsertTextFormat::PlainText,
          )
        end

        placeholders = required.map_with_index do |parameter, index|
          "${#{index + 1}:#{parameter.external_name}}"
        end
        LSProtocol::CompletionItem.new(
          label: entry.name,
          kind: LSProtocol::CompletionItemKind::Method,
          detail: entry.signature,
          insert_text: "#{entry.name}(#{placeholders.join(", ")})",
          insert_text_format: LSProtocol::InsertTextFormat::Snippet,
        )
      end
    end
  end
end
