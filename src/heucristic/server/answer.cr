require "../index/entry"
require "../document/span"

module Heucristic
  module Server
    record Answer,
      entries : Array(Index::Entry),
      spans : Array(Document::Span),
      notes : Array(String) do
      NONE = new(Array(Index::Entry).new, Array(Document::Span).new, Array(String).new)

      def self.of(entries : Array(Index::Entry)) : Answer
        new(entries, Array(Document::Span).new, Array(String).new)
      end

      def self.of(entries : Array(Index::Entry), note : String) : Answer
        new(entries, Array(Document::Span).new, [note])
      end

      def self.note(note : String) : Answer
        new(Array(Index::Entry).new, Array(Document::Span).new, [note])
      end
    end
  end
end
