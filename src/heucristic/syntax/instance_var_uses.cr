require "compiler/crystal/syntax"
require "../index/owner"
require "./scoped"

module Heucristic
  module Syntax
    class InstanceVarUses < Scoped
      getter locations : Array(Crystal::Location)

      def self.of(
        tree : Crystal::ASTNode,
        path : String?,
        name : String,
        owner : Index::Identity,
        version : CrystalVersion::Detected,
      ) : Array(Crystal::Location)
        finder = new(path, name, owner, version)
        tree.accept(finder)
        finder.locations
      end

      def initialize(
        path : String?,
        @name : String,
        @owner : Index::Identity,
        version : CrystalVersion::Detected,
      ) : Nil
        super(path, version)
        @locations = Array(Crystal::Location).new
      end

      def visit(node : Crystal::TypeDeclaration) : Bool
        false
      end

      def visit(node : Crystal::InstanceVar | Crystal::ClassVar) : Bool
        location = node.location
        @locations << location if location && node.name == @name && context.owner == @owner
        true
      end
    end
  end
end
