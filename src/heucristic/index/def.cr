require "../document/span"
require "./arity"
require "./owner"
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
      owner : Owner,
      receiver : Receiver,
      path : String,
      name_span : Document::Span,
      arity : Arity,
      parameters : Array(Parameter),
      return_type : Restriction do
      def qualified : String
        case (namespace = owner)
        in TopLevel then name
        in String   then "#{namespace}#{receiver.metaclass? ? "." : "#"}#{name}"
        end
      end

      def signature : String
        Signature.render(receiver.metaclass? ? "self" : nil, name, parameters, return_type)
      end
    end
  end
end
