require "../index/entry"
require "../document/span"

module Heucristic
  module Server
    record Answer,
      entries : Array(Index::Entry),
      spans : Array(Document::Span),
      descriptions : Array(String),
      notes : Array(String),
      files : Array(String) = Array(String).new do
      def self.of(entries : Array(Index::Entry)) : Answer
        new(entries, Array(Document::Span).new, Array(String).new, Array(String).new)
      end

      def self.note(note : String) : Answer
        new(Array(Index::Entry).new, Array(Document::Span).new, Array(String).new, [note])
      end

      def self.files(files : Array(String), description : String) : Answer
        new(
          Array(Index::Entry).new,
          Array(Document::Span).new,
          [description],
          Array(String).new,
          files,
        )
      end
    end
  end
end
