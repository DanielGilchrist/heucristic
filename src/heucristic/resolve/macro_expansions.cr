require "compiler/crystal/syntax"
require "../index/macro_call"
require "../index/workspace"
require "../syntax"
require "../syntax/broken"
require "../syntax/defined_variables"
require "../syntax/expansion_locals"
require "./binding"
require "./body_facts"
require "./memos"
require "./methods"
require "./resolution"
require "./typer"
require "./visit"

module Heucristic
  module Resolve
    class MacroExpansions
      record Expanded, tree : Crystal::ASTNode, isolated : Syntax::ExpansionLocals::Isolated

      def initialize(
        @workspace : Index::Workspace,
        @methods : Methods,
        @memos : Memos,
        @typer : Typer,
      ) : Nil
      end

      def result(
        call : Crystal::Call,
        context : Syntax::Context,
        outcome : Unknown,
        receiver : Resolved,
        shape : Methods::Call,
        locals : Array(Binding),
        visiting : Array(Visit),
      ) : Resolution
        return outcome unless outcome.reason.unresolved_name?
        annotated = inside_annotation(call, context)
        return annotated if annotated

        inherited = @methods.class_macros(receiver, shape)
        if Index::MacroCall.like?(call, @workspace) || !inherited.empty?
          return expansion(call, context, locals, visiting)
        end
        return outcome unless call.obj.nil?

        owner = Index::MacroCall.enclosing(context.ancestors, @workspace)
        return outcome unless owner

        detail = "`#{call.name}` sits inside the `#{owner.name}` macro, which decides what it means"
        Unknown.new(:macro, detail)
      end

      def inside_annotation(call : Crystal::Call, context : Syntax::Context) : Unknown?
        return unless context.ancestors.any?(Crystal::Annotation)

        detail = "`#{call.name}` sits inside an annotation, whose arguments only macros read"
        Unknown.new(:macro, detail)
      end

      def expansion(
        call : Crystal::Call,
        context : Syntax::Context,
        locals : Array(Binding),
        visiting : Array(Visit),
      ) : Resolution
        expanded = expanded_result(call, context, locals, visiting)
        return expanded if expanded

        Unknown.new(:macro, "`#{call.name}` is a macro; its expansion is not typed")
      end

      def assigning(name : String, context : Syntax::Context, facts : BodyFacts?) : String?
        path = context.path
        return unless path && facts

        assigners = @memos.macro_assigned[facts.object_id] ||= assigners(facts, context, path)
        assigners[name]?
      end

      private def expanded_result(
        call : Crystal::Call,
        context : Syntax::Context,
        locals : Array(Binding),
        visiting : Array(Visit),
      ) : Resolution?
        location = call.name_location
        path = context.path
        return unless location && path

        found = @workspace.expansion(path, location.line_number, location.column_number)
        return unless found && found.name == call.name

        key = ExpansionVisit.new(path, location.line_number, location.column_number, call.name)
        return key.cycle if visiting.includes?(key)

        expanded = expansion_of(call, found, context, path)
        if expanded.is_a?(Syntax::Broken)
          detail = "the expansion of `#{call.name}` does not parse: #{expanded.message}"
          return Unknown.new(:macro, detail)
        end

        tree = expanded.tree
        statements = tree.is_a?(Crystal::Expressions) ? tree.expressions : [tree]
        last = statements.last?
        return TypeRef.of(:nil) unless last

        inner = visiting + [key]
        bound = bindings(statements, expanded.isolated, call, context, inner, locals)
        @typer.type_of(last, context, inner, bound + locals)
      end

      private def expansion_of(
        call : Crystal::Call,
        found : Index::MacroExpansion,
        context : Syntax::Context,
        path : String,
      ) : Expanded | Syntax::Broken
        @memos.expanded[call.object_id] ||= expand(call, found, context, path)
      end

      private def expand(
        call : Crystal::Call,
        found : Index::MacroExpansion,
        context : Syntax::Context,
        path : String,
      ) : Expanded | Syntax::Broken
        definition = context.def_node
        root = context.ancestors.first?
        variables = if definition
                      Syntax::DefinedVariables.of(definition)
                    elsif root
                      Syntax::DefinedVariables.at_top_level(root)
                    else
                      Set(String).new
                    end
        at = call.location || Crystal::Location.new(path, 1, 1)
        tree = Syntax.parse_fragment(found.source, path, at, variables)
        return tree if tree.is_a?(Syntax::Broken)

        Expanded.new(tree, Syntax::ExpansionLocals.isolate(tree))
      end

      private def bindings(
        statements : Array(Crystal::ASTNode),
        isolated : Syntax::ExpansionLocals::Isolated,
        call : Crystal::Call,
        context : Syntax::Context,
        visiting : Array(Visit),
        locals : Array(Binding),
      ) : Array(Binding)
        bound = Array(Binding).new(isolated.names.size)
        isolated.nested.each do |name|
          detail = "`#{name.lchop(Syntax::ExpansionLocals::PREFIX)}` is assigned inside the " \
                   "expansion of `#{call.name}` where flow decides its type"
          bound << Binding.new(name, Unknown.new(:macro, detail))
        end
        statements[0...-1].each do |statement|
          next unless statement.is_a?(Crystal::Assign)

          target = statement.target
          next unless target.is_a?(Crystal::Var)
          next if isolated.nested.includes?(target.name)

          typed = @typer.type_of(statement.value, context, visiting, bound + locals)
          bound.unshift(Binding.new(target.name, typed))
        end
        bound
      end

      private def assigners(
        facts : BodyFacts,
        context : Syntax::Context,
        path : String,
      ) : Hash(String, String)
        found = Hash(String, String).new
        facts.calls.each do |call|
          location = call.name_location
          next unless location

          expansion = @workspace.expansion(path, location.line_number, location.column_number)
          next unless expansion && expansion.name == call.name

          expanded = expansion_of(call, expansion, context, path)
          next if expanded.is_a?(Syntax::Broken)

          expanded.isolated.assigned.each { |assigned| found[assigned] ||= call.name }
        end
        found
      end
    end
  end
end
