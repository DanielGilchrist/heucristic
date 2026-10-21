require "../document/span"
require "./arity"
require "./owner"
require "./parameter"
require "./signature"
require "./receiver"
require "./visibility"

module Heucristic
  module Index
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
      yields : Bool,
      forwards_to : Crystal::ASTNode? = nil,
      node : Crystal::Def? = nil,
      with_yield : Bool = false,
      macro_body : Bool = false,
      abstract_def : Bool = false,
      visibility : Visibility = Visibility::Public,
      private_path : String? = nil,
      exit_call : String? = nil,
      reads : String? = nil do
      def visible_from?(path : String?) : Bool
        path.nil? || private_path.nil? || private_path == path
      end

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
