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
      return_type : Restriction,
      free_vars : Array(String),
      yields : Bool do
      def qualified : String
        case (namespace = owner)
        in TopLevel then name
        in String   then "#{namespace}#{receiver.metaclass? ? "." : "#"}#{name}"
        end
      end

      def signature : String
        Signature.render(receiver.metaclass? ? "self" : nil, name, parameters, return_type)
      end

      def identity : String
        "#{qualified}(#{parameters.map(&.identity).join(", ")})"
      end

      def shape : String
        "#{qualified}(#{parameters.map(&.shape).join(", ")})"
      end
    end
  end
end
