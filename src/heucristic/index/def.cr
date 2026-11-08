require "../document/span"
require "./arity"
require "./owner"
require "./parameter"
require "./signature"
require "./receiver"
require "./visibility"
require "./instance_var_read"

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
      reads : InstanceVarRead? = nil do
      def self.synthetic(
        name : String,
        owner : Owner,
        path : String,
        name_span : Document::Span,
        receiver : Receiver = Receiver::Instance,
        parameters : Array(Parameter) = Array(Parameter).new,
        return_type : Restriction = Unrestricted.new,
        arity : Arity = Arity.new(parameters.size, 0, false),
        visibility : Visibility = Visibility::Public,
        reads : InstanceVarRead? = nil,
      ) : Def
        new(
          name: name,
          owner: owner,
          receiver: receiver,
          path: path,
          name_span: name_span,
          arity: arity,
          parameters: parameters,
          return_type: return_type,
          free_vars: Array(String).new,
          yields: false,
          visibility: visibility,
          reads: reads,
        )
      end

      def self.forwarder(
        name : String,
        owner : Owner,
        path : String,
        name_span : Document::Span,
        target : Crystal::ASTNode,
      ) : Def
        splat = Parameter.new("args", "args", Unrestricted.new, nil, :splat)
        new(
          name: name,
          owner: owner,
          receiver: Receiver::Instance,
          path: path,
          name_span: name_span,
          arity: Arity.anything,
          parameters: [splat],
          return_type: Unrestricted.new,
          free_vars: Array(String).new,
          yields: false,
          forwards_to: target,
        )
      end

      def visible_from?(path : String?) : Bool
        path.nil? || private_path.nil? || private_path == path
      end

      def qualified : String
        case (namespace = owner)
        in TopLevel then name
        in Identity then "#{namespace}#{receiver.metaclass? ? "." : "#"}#{name}"
        end
      end

      def signature : String
        Signature.render(receiver.metaclass? ? "self" : nil, name, parameters, return_type)
      end

      def identity : String
        "#{qualified}(#{parameters.map(&.identity).join(", ")})"
      end

      def unrestricted_identity : String
        "#{qualified}(#{parameters.map(&.unrestricted_identity).join(", ")})"
      end
    end
  end
end
