require "compiler/requires"
require "../../src/heucristic/index/macro_expansion"

module Semantic
  class Expansions < Crystal::Visitor
    MAX_NESTING = 4

    record Target, found : Crystal::Macro, scope : Crystal::Type

    getter found : Array(Heucristic::Index::MacroExpansion)

    def initialize(@program : Crystal::Program, @root : String) : Nil
      @found = Array(Heucristic::Index::MacroExpansion).new
      @scopes = [@program] of Crystal::Type
      @defs = Array(Crystal::Def).new
      @files = Array(String).new
    end

    def visit(node : Crystal::Require) : Bool
      node.expanded.try &.accept(self)
      false
    end

    def visit(node : Crystal::FileNode) : Bool
      return false unless project?(node.filename)

      @files << node.filename
      node.node.accept(self)
      @files.pop
      false
    end

    def visit(node : Crystal::ClassDef) : Bool
      within(node.resolved_type?, node.body)
    end

    def visit(node : Crystal::ModuleDef) : Bool
      within(node.resolved_type?, node.body)
    end

    def visit(node : Crystal::Def) : Bool
      @defs << node
      node.body.accept(self)
      @defs.pop
      false
    end

    def visit(node : Crystal::Call) : Bool
      expand(node) if expandable?
      true
    end

    def visit(node : Crystal::ASTNode) : Bool
      true
    end

    private def within(type : Crystal::Type?, body : Crystal::ASTNode) : Bool
      return false unless type

      @scopes << type
      body.accept(self)
      @scopes.pop
      false
    end

    private def expandable? : Bool
      !@files.empty? && (!@defs.empty? || @scopes.size == 1)
    end

    private def expand(call : Crystal::Call) : Nil
      return if call.expanded

      target = macro_for(call, current_scope)
      return unless target

      location = call.name_location || call.location
      path = location.try(&.original_filename)
      return unless location && path

      source = expansion_source(target, call, @defs.last?, MAX_NESTING)
      return unless source

      @found << Heucristic::Index::MacroExpansion.new(
        path, location.line_number, location.column_number, call.name, source
      )
    end

    private def expansion_source(
      target : Target,
      call : Crystal::Call,
      definition : Crystal::Def?,
      nesting : Int32,
    ) : String?
      source = @program.expand_macro(target.found, call, target.scope, target.scope, definition)[0]
      nesting > 0 ? inline_nested(source, target.scope, definition, nesting - 1) : source
    rescue Crystal::CodeError
      nil
    end

    private def inline_nested(
      source : String,
      scope : Crystal::Type,
      definition : Crystal::Def?,
      nesting : Int32,
    ) : String
      tree = Crystal::Parser.parse(source)
      statements = tree.is_a?(Crystal::Expressions) ? tree.expressions : [tree]
      replaced = false
      rendered = statements.map do |statement|
        inner = nested_source(statement, scope, definition, nesting)
        replaced ||= !inner.nil?
        inner || statement.to_s
      end
      replaced ? rendered.join('\n') : source
    rescue Crystal::CodeError
      source
    end

    private def nested_source(
      statement : Crystal::ASTNode,
      scope : Crystal::Type,
      definition : Crystal::Def?,
      nesting : Int32,
    ) : String?
      return unless statement.is_a?(Crystal::Call) && statement.obj.is_a?(Crystal::Path)

      target = macro_for(statement, scope)
      target ? expansion_source(target, statement, definition, nesting) : nil
    end

    private def current_scope : Crystal::Type
      @defs.last?.try(&.owner?) || @scopes.last
    end

    private def macro_for(call : Crystal::Call, scope : Crystal::Type) : Target?
      receiver = call.obj
      if receiver.nil?
        found = macro_on(scope, call) || macro_elsewhere(call, scope)
        return found ? Target.new(found, scope) : nil
      end
      return unless receiver.is_a?(Crystal::Path)

      owner = scope.lookup_path(receiver)
      return unless owner.is_a?(Crystal::Type)

      owner = owner.remove_alias

      found = macro_on(owner.metaclass, call)
      found ? Target.new(found, owner) : nil
    end

    private def macro_elsewhere(call : Crystal::Call, scope : Crystal::Type) : Crystal::Macro?
      if scope.instance_type.module?
        found = macro_on(@program.object, call)
        return found if found
      end
      found = macro_on(@program, call)
      return found if found

      file = @files.last?
      file_module = file ? @program.file_module?(file) : nil
      file_module ? macro_on(file_module, call) : nil
    end

    private def macro_on(type : Crystal::Type, call : Crystal::Call) : Crystal::Macro?
      found = type.lookup_macro(call.name, call.args, call.named_args)
      found if found.is_a?(Crystal::Macro)
    end

    private def project?(path : String) : Bool
      path.starts_with?(@root + "/") && !path.starts_with?(File.join(@root, "lib") + "/")
    end
  end
end
