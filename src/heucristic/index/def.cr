require "../document/span"
require "./arity"

module Heucristic
  module Index
    enum Receiver
      Instance
      Metaclass
    end

    record Def,
      name : String,
      owner : String,
      receiver : Receiver,
      path : String,
      name_span : Document::Span,
      arity : Arity,
      signature : String do
      def qualified : String
        separator = receiver.metaclass? ? "." : "#"
        owner.empty? ? name : "#{owner}#{separator}#{name}"
      end
    end
  end
end
