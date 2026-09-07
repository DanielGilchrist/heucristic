require "lsprotocol"
require "./text"

module Heucristic
  module Document
    module Edit
      extend self

      def apply(
        text : Text,
        change : LSProtocol::TextDocumentContentChangeEvent,
      ) : Text | OutOfRange
        case change
        in LSProtocol::TextDocumentContentChangeWholeDocument
          Text.new(change.text)
        in LSProtocol::TextDocumentContentChangePartial
          from = text.offset(change.range.start)
          return from if from.is_a?(OutOfRange)
          to = text.offset(change.range.end)
          return to if to.is_a?(OutOfRange)

          text.splice(from, to, change.text)
        end
      end

      def apply_all(
        text : Text,
        changes : Array(LSProtocol::TextDocumentContentChangeEvent),
      ) : Text | OutOfRange
        changes.reduce(text) do |current, change|
          return current if current.is_a?(OutOfRange)

          apply(current, change)
        end
      end
    end
  end
end
