require "lsprotocol"
require "../document/text"
require "./uri"

module Heucristic
  module Server
    class Rename
      record Invalid, reason : String

      IDENTIFIER = /\A@{0,2}[A-Za-z_][A-Za-z0-9_]*[?!=]?\z/
      TYPE_NAME  = /\A[A-Z][A-Za-z0-9_]*\z/

      def edits(
        locations : Array(LSProtocol::Location),
        new_name : String,
        instance_var : Bool,
        type_name : Bool,
        & : String -> Document::Text?
      ) : LSProtocol::WorkspaceEdit | Invalid
        replacement = instance_var && !new_name.starts_with?('@') ? "@#{new_name}" : new_name
        if type_name && !TYPE_NAME.matches?(replacement)
          return Invalid.new("#{new_name} is not a valid type name")
        end
        unless IDENTIFIER.matches?(replacement)
          return Invalid.new("#{new_name} is not a valid name")
        end

        changes = Hash(URI, Array(LSProtocol::TextEdit)).new
        locations.each do |location|
          uri = location.uri
          path = Uri.to_path(uri.to_s)
          text = path.is_a?(String) ? yield(path) : nil
          range = type_name && text ? last_segment(location.range, text) : location.range
          edit = LSProtocol::TextEdit.new(range: range, new_text: replacement)
          (changes[uri] ||= Array(LSProtocol::TextEdit).new) << edit
        end
        changes.each_value do |edits|
          edits.uniq! { |edit| {edit.range.start.line, edit.range.start.character} }
          edits.sort_by! { |edit| {edit.range.start.line, edit.range.start.character} }
        end
        LSProtocol::WorkspaceEdit.new(changes: changes)
      end

      private def last_segment(range : LSProtocol::Range, text : Document::Text) : LSProtocol::Range
        from = text.offset(range.start)
        to = text.offset(range.end)
        return range if from.is_a?(Document::OutOfRange) || to.is_a?(Document::OutOfRange)

        written = text.source.byte_slice(from, to - from)
        separator = written.rindex("::")
        return range unless separator

        skipped = written[0, separator + 2].size
        character = range.start.character + skipped
        start = LSProtocol::Position.new(line: range.start.line, character: character)
        LSProtocol::Range.new(start: start, end: range.end)
      end
    end
  end
end
