require "compiler/crystal/syntax"
require "../index/owner"

module Heucristic
  module Syntax
    record Context,
      enclosing : Array(String),
      type_vars : Array(String),
      def_node : Crystal::Def?,
      blocks : Array(Crystal::Call) do
      def self.new(
        enclosing : Array(String),
        type_vars : Array(String),
        def_node : Crystal::Def?,
      ) : Context
        new(enclosing, type_vars, def_node, Array(Crystal::Call).new)
      end

      def owner : Index::Owner
        enclosing.last? || Index::TopLevel.new
      end
    end

    record OnDef, node : Crystal::Def, context : Context
    record OnCall, node : Crystal::Call, context : Context
    record OnPath, node : Crystal::Path, context : Context, segment : Int32
    record OnVar, name : String, context : Context
    record OnInstanceVar, name : String, context : Context

    alias Target = OnDef | OnCall | OnPath | OnVar | OnInstanceVar
  end
end
