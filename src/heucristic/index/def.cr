require "../document/span"
require "./arity"
require "./parameter"
require "./signature"

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
      parameters : Array(Parameter),
      return_type : Restriction do
      def qualified : String
        separator = receiver.metaclass? ? "." : "#"
        owner.empty? ? name : "#{owner}#{separator}#{name}"
      end

      def signature : String
        Signature.render(receiver.metaclass? ? "self" : nil, name, parameters, return_type)
      end
    end
  end
end
