require "compiler/crystal/syntax"
require "./scoped"
require "./control_kind"

module Heucristic
  module Syntax
    class Uses < Scoped
      record CallSite, call : Crystal::Call, context : Context
      record PathSite, path : Crystal::Path, context : Context
      record CaseSite, node : Crystal::Case, context : Context
      record GenericSite, node : Crystal::Generic, context : Context
      record ControlSite, node : Crystal::ASTNode, kind : ControlKind, context : Context
      record DefSite, node : Crystal::Def, context : Context
      record InstanceVarSite,
        node : Crystal::InstanceVar,
        assign : Crystal::Assign?,
        context : Context

      getter calls : Array(CallSite)
      getter paths : Array(PathSite)
      getter cases : Array(CaseSite)
      getter generics : Array(GenericSite)
      getter controls : Array(ControlSite)
      getter def_sites : Array(DefSite)
      getter instance_vars : Array(InstanceVarSite)
      getter multi_assigned : Set(String)

      def self.in(
        tree : Crystal::ASTNode,
        path : String?,
        version : CrystalVersion::Detected,
      ) : Uses
        uses = new(path, version)
        tree.accept(uses)
        uses
      end

      def initialize(path : String?, version : CrystalVersion::Detected) : Nil
        super(path, version)
        @calls = Array(CallSite).new
        @paths = Array(PathSite).new
        @cases = Array(CaseSite).new
        @generics = Array(GenericSite).new
        @controls = Array(ControlSite).new
        @def_sites = Array(DefSite).new
        @instance_vars = Array(InstanceVarSite).new
        @written = Set(UInt64).new
        @multi_assigned = Set(String).new
      end

      def visit(node : Crystal::MultiAssign) : Bool
        node.targets.each do |target|
          next unless target.is_a?(Crystal::InstanceVar)

          @written << target.object_id
          @multi_assigned << target.name
        end
        super
      end

      def visit(node : Crystal::OpAssign) : Bool
        target = node.target
        if target.is_a?(Crystal::InstanceVar)
          @written << target.object_id
          @multi_assigned << target.name
        end
        super
      end

      def visit(node : Crystal::Assign) : Bool
        target = node.target
        if target.is_a?(Crystal::InstanceVar) && target.location
          @written << target.object_id
          @instance_vars << InstanceVarSite.new(target, node, context)
        end
        super
      end

      def visit(node : Crystal::TypeDeclaration) : Bool
        var = node.var
        @written << var.object_id if var.is_a?(Crystal::InstanceVar)
        super
      end

      def visit(node : Crystal::InstanceVar) : Bool
        unless @written.includes?(node.object_id) || node.location.nil?
          @instance_vars << InstanceVarSite.new(node, nil, context)
        end
        super
      end

      def visit(node : Crystal::Def) : Bool
        descend = super
        @def_sites << DefSite.new(node, context) if node.name_location
        descend
      end

      def visit(node : Crystal::Generic) : Bool
        @generics << GenericSite.new(node, context) if node.location
        super
      end

      def visit(node : Crystal::Yield | Crystal::Return | Crystal::Break | Crystal::Next) : Bool
        kind = case node
               in Crystal::Yield   then ControlKind::Yield
               in Crystal::Return  then ControlKind::Return
               in Crystal::Break   then ControlKind::Break
               in Crystal::Next    then ControlKind::Next
               in Crystal::ASTNode then nil
               end
        @controls << ControlSite.new(node, kind, context) if kind && node.location
        super
      end

      def visit(node : Crystal::Case) : Bool
        @cases << CaseSite.new(node, context) if node.exhaustive? && node.location
        super
      end

      def visit(node : Crystal::Call) : Bool
        @calls << CallSite.new(node, context) if node.name_location
        super
      end

      def visit(node : Crystal::Path) : Bool
        @paths << PathSite.new(node, context) if node.location
        true
      end
    end
  end
end
