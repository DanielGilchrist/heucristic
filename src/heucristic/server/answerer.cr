require "lsprotocol"
require "../document/point"
require "../document/span"
require "../document/text"
require "../index/entry"
require "../index/macro_call"
require "../index/macro_target"
require "../index/workspace"
require "../requires"
require "../resolve/local_declarations"
require "../resolve/methods"
require "../resolve/receiver"
require "../resolve/types"
require "../syntax"
require "../syntax/parameter_name"
require "../syntax/target"
require "./answer"
require "./macro_lookup"
require "./parameter_hint"
require "./source_paths"
require "./undeclared"
require "./uri"

module Heucristic
  module Server
    class Answerer
      RESCUE_KEYWORD = "rescue"

      def initialize(
        @workspace : Index::Workspace,
        @types : Resolve::Types,
        @methods : Resolve::Methods,
        @receiver : Resolve::Receiver,
        @hints : ParameterHint,
        @macros : MacroLookup,
        @sources : SourcePaths,
      ) : Nil
        @undeclared = Undeclared.new(@workspace)
      end

      def answer(
        target : Syntax::Target,
        path : String,
        text : Document::Text,
        root : String,
      ) : Answer
        case target
        in Syntax::OnDef  then answer_def(target)
        in Syntax::OnCall then answer_call(target, root)
        in Syntax::OnPath then answer_path(target, root)
        in Syntax::OnVar
          anchored = anchored_at(path, target.location)
          anchored.empty? ? answer_var(target, text, root) : Answer.of(anchored)
        in Syntax::OnInstanceVar then answer_instance_var(target)
        in Syntax::OnName
          anchored = anchored_at(path, target.location)
          return Answer.of(anchored) unless anchored.empty?

          Answer.note("nothing is declared by `#{target.name}` here")
        in Syntax::OnRequire then answer_require(target, path, root)
        end
      end

      def sections(answer : Answer, root : String) : Array(String)
        sections = answer.descriptions.dup
        if sections.empty? && answer.notes.empty?
          sections.concat(describe_all(answer.entries, root))
        end
        sections.concat(answer.notes)
      end

      def locations(answer : Answer, uri : String) : Array(LSProtocol::Location)
        locations = Array(LSProtocol::Location).new(answer.entries.size)
        answer.entries.each do |entry|
          location = locate(entry)
          locations << location if location
        end
        answer.spans.each do |span|
          locations << LSProtocol::Location.new(range: span.to_range, uri: URI.parse(uri))
        end
        answer.macros.each do |definition|
          uri_of = URI.parse(Uri.from_path(definition.path))
          locations << LSProtocol::Location.new(range: definition.name_span.to_range, uri: uri_of)
        end
        answer.files.each do |file|
          origin = LSProtocol::Position.new(line: 0, character: 0)
          range = LSProtocol::Range.new(start: origin, end: origin)
          locations << LSProtocol::Location.new(range: range, uri: URI.parse(Uri.from_path(file)))
        end
        locations
      end

      def describe_all(entries : Array(Index::Entry), root : String) : Array(String)
        namespaces = entries.select(Index::Namespace)
        return entries.map { |entry| describe(entry, root) } if namespaces.size < 2

        primary = namespaces.find(&.is_a?(Index::ClassNamespace)) || namespaces[0]
        primary = namespaces.select(Index::ClassNamespace).find(&.type_vars.empty?.!) || primary
        others = entries.reject(Index::Namespace).map { |entry| describe(entry, root) }
        others.unshift(fence(namespace_header(primary), "# reopened in #{namespaces.size} places"))
      end

      def locate(entry : Index::Entry) : LSProtocol::Location?
        site = @macros.site_of(entry)
        unless site
          return if Index::MacroTarget.generated?(entry.path)

          return LSProtocol::Location.new(
            range: entry.name_span.to_range, uri: URI.parse(Uri.from_path(entry.path))
          )
        end

        path = site.expanded_path
        line = site.expanded_line
        column = site.expanded_column
        return unless path && line && column

        start = LSProtocol::Position.new(line: (line - 1).to_u32, character: (column - 1).to_u32)
        finish = LSProtocol::Position.new(
          line: (line - 1).to_u32, character: (column - 1 + site.name.size).to_u32
        )
        range = LSProtocol::Range.new(start: start, end: finish)
        LSProtocol::Location.new(range: range, uri: URI.parse(Uri.from_path(path)))
      end

      private def answer_require(target : Syntax::OnRequire, path : String, root : String) : Answer
        string = target.node.string
        case (resolved = Requires.new(@sources.paths(root)).resolve(string, path))
        in Requires::Unresolved
          tried = resolved.tried.join('\n') { |candidate| "- `#{candidate}`" }
          Answer.note("no file matches `require \"#{string}\"`, tried:\n#{tried}")
        in Array(String)
          return Answer.note("`require \"#{string}\"` matches no `.cr` files") if resolved.empty?

          Answer.files(resolved, "```\n#{resolved.join('\n')}\n```")
        end
      end

      private def anchored_at(path : String, location : Crystal::Location?) : Array(Index::Entry)
        entries = Array(Index::Entry).new
        file = @workspace.file(path)
        return entries unless file && location

        start = Document::Point.from(location)
        each_entry(file) do |entry|
          span = entry.name_span
          if span.start_line == start.line - 1 && span.start_character == start.column - 1
            entries << entry
          end
        end
        entries
      end

      private def each_entry(file : Index::File, & : Index::Entry ->) : Nil
        file.defs.each { |entry| yield entry }
        file.namespaces.each { |entry| yield entry }
        file.constants.each { |entry| yield entry }
        file.aliases.each { |entry| yield entry }
        file.instance_vars.each { |entry| yield entry }
      end

      private def answer_def(target : Syntax::OnDef) : Answer
        path = target.context.path
        entries = path ? @workspace.defs_at(path, target.node) : Array(Index::Def).new
        entries = generated_defs(target) if entries.empty?
        if entries.empty?
          return Answer.note("this def is not indexed yet, the file may have a syntax error")
        end

        Answer.of(Array(Index::Entry).new(entries.size).concat(entries))
      end

      private def generated_defs(target : Syntax::OnDef) : Array(Index::Def)
        node = target.node
        @workspace.named(node.name).select do |entry|
          Index::MacroTarget.generated?(entry.path) &&
            entry.owner == target.context.owner &&
            entry.receiver.metaclass? == !node.receiver.nil?
        end
      end

      private def answer_call(target : Syntax::OnCall, root : String) : Answer
        call = target.node
        enclosing = target.context.ancestors[0...-1]
        macro_call = Index::MacroCall.enclosing(enclosing, @workspace)
        if macro_call && call.obj.nil? && statement_of?(macro_call, enclosing)
          owner = "the `#{macro_call.name}` macro#{defined_at(macro_call, root)}"
          return Answer.note("`#{call.name}` is syntax of #{owner}, not a method call")
        end
        macros = Index::MacroCall.like?(call, @workspace) ? @workspace.macros(call.name) : nil
        if macros && !macros.empty? && !@receiver.macro_precedence(call, target.context).def?
          return Answer.macros(macros, macros.map { |definition| describe_macro(definition) })
        end

        receiver = @receiver.of_call(call, target.context)
        if receiver.is_a?(Resolve::Unknown)
          return Answer.note("receiver of `#{call.name}`: #{receiver}")
        end

        shape = @receiver.shape_of(call, target.context)
        found = if call.obj.nil? && Syntax::WellKnown::Super.named?(call.name)
                  @receiver.super_targets(call, target.context)
                else
                  @receiver.implementations(receiver, shape)
                end
        if found.empty?
          inherited = @methods.class_macros(receiver, shape)
          unless inherited.empty?
            described = inherited.map { |definition| describe_macro(definition) }
            return Answer.macros(inherited, described)
          end
        end
        if found.empty? && (action = @receiver.select_action(call, target.context))
          shape = @receiver.shape_of(action, target.context)
          found = @methods.lookup(receiver, shape)
        end
        if found.empty?
          forwarded = @receiver.forwarded_receiver(receiver)
          if forwarded.is_a?(Resolve::Resolved)
            receiver = forwarded
            found = @receiver.implementations(receiver, shape)
          end
        end
        if found.empty?
          unordered = @methods.missing(call.name, receiver)
          return Answer.note(unordered.detail) if unordered.reason.ambiguous?

          return Answer.note("no `#{call.name}` indexed on #{receiver}#{@macros.hint}")
        end

        site = Resolve::Receiver::Site.new(call.block, Resolve::Frame.of(target.context))
        sections = found.map do |entry|
          describe_resolved(entry, receiver, shape.types, site, root)
        end
        entries = Array(Index::Entry).new(found.size)
        found.each { |entry| entries << entry }
        Answer.new(entries, Array(Document::Span).new, sections, Array(String).new)
      end

      private def statement_of?(
        macro_call : Crystal::Call,
        ancestors : Array(Crystal::ASTNode),
      ) : Bool
        from = ancestors.index(&.same?(macro_call))
        return false unless from

        ancestors[(from + 1)..].all? do |node|
          node.is_a?(Crystal::Block) || node.is_a?(Crystal::Expressions)
        end
      end

      private def defined_at(macro_call : Crystal::Call, root : String) : String
        places = @workspace.macros(macro_call.name).map do |definition|
          "#{definition.path.sub(root + "/", "")}:#{definition.name_span.start_line + 1}"
        end
        places.empty? ? "" : " at #{places.join(" and ")}"
      end

      private def describe_macro(definition : Index::MacroDef) : String
        owner = definition.owner
        parameters = definition.parameters.join(", ")
        String.build do |io|
          io << "```crystal\n"
          io << "# " << owner << '\n' if owner.is_a?(Index::Identity)
          io << "macro " << definition.name << '(' << parameters << ")\n```"
        end
      end

      private def answer_path(target : Syntax::OnPath, root : String) : Answer
        node = target.node
        context = target.context
        scope = Resolve::Scope.of(context)
        names = node.names[0, target.segment + 1]
        located = @types.locate_any(Syntax::Named.new(names, node.global?), scope)
        return Answer.note(located.to_s) if located.is_a?(Resolve::Unknown)

        entries = Array(Index::Entry).new
        @workspace.namespaces(located).each { |entry| entries << entry }
        @workspace.aliases(located).each { |entry| entries << entry }
        @workspace.constants(located).each { |entry| entries << entry }
        return Answer.of(entries) unless entries.empty?

        @undeclared.answer(located, root)
      end

      private def answer_var(target : Syntax::OnVar, text : Document::Text, root : String) : Answer
        resolution = @receiver.variable(target.name, target.context)
        notes = [typed(resolution)]
        if resolution.is_a?(Resolve::Unknown)
          @hints.for(target.name, target.context, root).try { |hint| notes << hint }
        end
        spans = Array(Document::Span).new
        if (rescued = rescue_variable(target, text))
          spans << rescued
        else
          add_span(spans, text, introduced_at(target.name, target.context), target.name.size)
        end
        Answer.new(Array(Index::Entry).new, spans, notes, Array(String).new)
      end

      private def rescue_variable(target : Syntax::OnVar, text : Document::Text) : Document::Span?
        clause = target.context.ancestors.reverse_each.find do |node|
          node.is_a?(Crystal::Rescue) && node.name == target.name
        end
        location = clause.try(&.location)
        return unless location

        text.span_of(target.name, location, RESCUE_KEYWORD.size)
      end

      private def parameter_named(definition : Crystal::Def, name : String) : Crystal::Arg?
        splat = definition.double_splat
        return splat if splat && splat.name == name

        definition.args.find(&.name.==(name))
      end

      private def introduced_at(name : String, context : Syntax::Context) : Crystal::Location?
        context.blocks.reverse_each do |call|
          argument = call.block.try(&.args.find(&.name.==(name)))
          return argument.location if argument
        end

        definition = context.def_node
        body = definition ? definition.body : context.ancestors.first?
        return unless body
        if definition && (parameter = parameter_named(definition, name))
          return Syntax::ParameterName.location(parameter)
        end
        if definition && (block_arg = definition.block_arg) && block_arg.name == name
          return block_arg.location
        end
        if (declaration = Resolve::LocalDeclarations.find(body, name))
          return declaration.var.location
        end

        found = Resolve::LocalAssignments.first_target(body, name).try(&.location)
        return found if found

        index = context.proc_index
        introduced_at(name, context.outside_proc(index)) if index
      end

      private def answer_instance_var(target : Syntax::OnInstanceVar) : Answer
        note = typed(@receiver.instance_var(target.name, target.context))
        entries = declared_instance_vars(target)
        Answer.new(entries, Array(Document::Span).new, [note], Array(String).new)
      end

      private def declared_instance_vars(target : Syntax::OnInstanceVar) : Array(Index::Entry)
        entries = Array(Index::Entry).new
        owner = target.context.owner
        return entries unless owner.is_a?(Index::Identity)

        levels = [owner]
        chain = @types.ancestors(owner)
        levels.concat(chain) unless chain.is_a?(Resolve::Unknown)
        levels.each do |level|
          @workspace.instance_vars_of(level).each do |declared|
            entries << declared if declared.name == target.name
          end
          return entries unless entries.empty?
        end
        entries
      end

      private def typed(resolution : Resolve::Resolution) : String
        case resolution
        in Resolve::Resolved then fence(resolution.to_s)
        in Resolve::Unknown  then resolution.to_s
        end
      end

      private def fence(*lines : String) : String
        fence(lines.to_a)
      end

      private def fence(lines : Array(String)) : String
        "```crystal\n#{lines.join('\n')}\n```"
      end

      private def add_span(
        spans : Array(Document::Span),
        text : Document::Text,
        location : Crystal::Location?,
        size : Int32,
      ) : Nil
        return unless location

        span = text.span_at(location, size)
        spans << span if span
      end

      private def describe_resolved(
        entry : Index::Def,
        receiver : Resolve::Resolved,
        arguments : Array(Resolve::Resolution),
        site : Resolve::Receiver::Site,
        root : String,
      ) : String
        signature = @receiver.signature(entry, receiver, arguments, site)
        lines = ["# #{entry.qualified}"]
        @macros.provenance(entry, root).try { |line| lines << line }
        lines << signature
        returning = @receiver.return_type(entry, receiver, arguments, site)
        lines << "# returns #{returning}" if returning.is_a?(Resolve::Unknown)
        fence(lines)
      end

      private def describe(entry : Index::Entry, root : String) : String
        case entry
        in Index::Def
          lines = ["# #{entry.qualified}"]
          @macros.provenance(entry, root).try { |line| lines << line }
          lines << entry.signature
          fence(lines)
        in Index::Namespace
          fence(declared_by(entry, root) + [namespace_header(entry)])
        in Index::Alias
          fence(declared_by(entry, root) + ["alias #{entry.name} = #{entry.target}"])
        in Index::InstanceVar
          fence("# #{entry.owner}", "#{entry.name} : #{entry.type}")
        in Index::Constant
          value = entry.value
          rendered = entry.name
          rendered = "#{rendered} = #{value} # : #{@receiver.type_of(entry)}" if value.is_a?(String)
          fence(declared_by(entry, root) + [rendered])
        end
      end

      private def declared_by(entry : Index::Entry, root : String) : Array(String)
        lines = Array(String).new
        provenance = @macros.provenance(entry, root)
        if provenance
          lines << provenance
        elsif Index::MacroTarget.generated?(entry.path)
          lines << "# declared by a macro"
        end
        lines
      end

      private def namespace_header(entry : Index::Namespace) : String
        case entry
        in Index::ClassNamespace
          String.build do |io|
            io << "abstract " if entry.abstract_type
            io << entry.keyword << ' ' << entry.name
            io << '(' << entry.type_vars.join(", ") << ')' unless entry.type_vars.empty?
            superclass = entry.superclass
            io << " < " << superclass unless superclass.is_a?(Index::Unrestricted)
          end
        in Index::ModuleNamespace
          generics = entry.type_vars.empty? ? "" : "(#{entry.type_vars.join(", ")})"
          "#{entry.keyword} #{entry.name}#{generics}"
        in Index::EnumNamespace
          base = entry.base_type
          suffix = base.is_a?(Index::Unrestricted) ? "" : " : #{base}"
          "#{entry.keyword} #{entry.name}#{suffix}"
        in Index::LibNamespace, Index::AnnotationNamespace
          "#{entry.keyword} #{entry.name}"
        end
      end
    end
  end
end
