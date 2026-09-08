require "../index/entry"
require "../document/span"

module Heucristic
  module Server
    record Answer,
      entries : Array(Index::Entry),
      spans : Array(Document::Span),
      descriptions : Array(String),
      notes : Array(String) do
      def self.of(entries : Array(Index::Entry)) : Answer
        new(entries, Array(Document::Span).new, Array(String).new, Array(String).new)
      end

      def self.note(note : String) : Answer
        new(Array(Index::Entry).new, Array(Document::Span).new, Array(String).new, [note])
      end
    end
  end
end
