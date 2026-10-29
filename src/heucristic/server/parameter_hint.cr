require "../index/workspace"
require "../resolve/types"
require "../resolve/receiver"
require "./references"

module Heucristic
  module Server
    class ParameterHint
      CALLERS = 32
      SHOWN   =  8

      record Passed, where : String, value : Resolve::Resolution, defaulted : Bool

      def initialize(
        @workspace : Index::Workspace,
        @types : Resolve::Types,
        @receiver : Resolve::Receiver,
        @references : References,
      ) : Nil
      end

      def for(name : String, context : Syntax::Context, root : String) : String?
        definition = context.def_node
        path = context.path
        return unless definition && path

        entry = @workspace.defs_at(path, definition).first?
        return unless entry

        parameter = entry.parameters.find(&.name.==(name))
        return unless parameter && parameter.restriction.is_a?(Index::Unrestricted)
        unless parameter.kind.positional? || parameter.kind.keyword?
          return "`#{name}` collects several arguments, so no single call states its type."
        end

        callers = @references.callers([entry], CALLERS)
        passed = callers.uses.map { |use| passed(use, entry, parameter, root) }
        render(name, entry, passed, callers)
      end

      private def passed(
        use : Index::CallUse,
        entry : Index::Def,
        parameter : Index::Parameter,
        root : String,
      ) : Passed
        where = use.sites.path.sub(root + "/", "")
        location = use.call.name_location || use.call.location
        where = "#{where}:#{location.line_number}" if location
        given = given(use, entry, parameter)
        return Passed.new(where, given, false) if given

        Passed.new(where, default(entry, parameter), true)
      end

      private def given(
        use : Index::CallUse,
        entry : Index::Def,
        parameter : Index::Parameter,
      ) : Resolve::Resolution?
        shape = @receiver.shape_of(use.call, use.context)
        named = shape.named_arguments.find(&.name.==(parameter.external_name))
        return named.value if named
        return unless parameter.kind.positional?

        index = entry.parameters.select(&.kind.positional?).index(parameter)
        return unless index

        splat = use.call.args.index(&.is_a?(Crystal::Splat))
        if splat && index >= splat
          detail = "a splat argument spreads into `#{parameter.name}`"
          return Resolve::Unknown.new(:unsupported, detail)
        end
        shape.arguments[index]?
      end

      private def default(entry : Index::Def, parameter : Index::Parameter) : Resolve::Resolution
        text = parameter.default
        unless text
          return Resolve::Unknown.new(:no_annotation, "no argument for `#{parameter.name}`")
        end

        evident = parameter.default_type
        unless evident
          return Resolve::Unknown.new(:inference_needed, "the default `#{text}` is not evident")
        end

        owner = entry.owner
        type_vars = owner.is_a?(String) ? @types.type_vars_of(owner) : Array(String).new
        scope = Resolve::Scope.new(owner, type_vars, Array(Resolve::Binding).new, entry.path)
        @types.resolve(evident, scope)
      end

      private def render(
        name : String,
        entry : Index::Def,
        passed : Array(Passed),
        callers : References::Callers,
      ) : String
        lines = Array(String).new
        if passed.empty?
          lines << "No indexed call is known to reach `#{entry.qualified}`."
        else
          lines << heading(name, entry, passed.size, callers.capped)
          passed.first(SHOWN).each { |item| lines << listed(item) }
          lines << "- and #{passed.size - SHOWN} more" if passed.size > SHOWN
        end
        if callers.untyped > 0
          lines << "#{callers.untyped} other #{noun(callers.untyped)} to `#{entry.name}` " \
                   "cannot be attributed, the receiver is not typed, and may reach it too."
        end
        suggestion(name, passed, callers).try { |line| lines << line }
        lines.join('\n')
      end

      private def shown(value : Resolve::Resolution) : String
        case value
        in Resolve::Resolved then "`#{value}`"
        in Resolve::Unknown  then value.to_s
        end
      end

      private def suggestion(
        name : String,
        passed : Array(Passed),
        callers : References::Callers,
      ) : String?
        return if passed.empty?
        return "Later calls were not examined, so no restriction is suggested." if callers.capped
        if callers.untyped > 0
          return "No restriction is suggested while some calls are not attributed."
        end

        members = Array(String).new
        untyped = 0
        passed.each do |item|
          value = item.value
          next untyped += 1 if unknown_within?(value)

          case value
          in Resolve::Unknown  then untyped += 1
          in Resolve::UnionRef then value.members.each { |member| members << member.to_s }
          in Resolve::TypeRef, Resolve::MetaRef, Resolve::TypeVar
            members << value.to_s
          end
        end
        if untyped > 0
          return "#{untyped} of #{passed.size} are not typed, so no restriction is suggested."
        end

        "Every call is typed: `#{name} : #{members.uniq.join(" | ")}` states what they pass."
      end

      private def calls(count : Int32) : String
        "#{count} #{noun(count)}"
      end

      private def noun(count : Int32) : String
        count == 1 ? "call" : "calls"
      end

      private def heading(name : String, entry : Index::Def, count : Int32, capped : Bool) : String
        calls = capped ? "The first #{calls(count)}" : "#{count} indexed #{noun(count)}"
        verb = count == 1 ? "passes" : "pass"
        "#{calls} to `#{entry.qualified}` #{verb} `#{name}`:"
      end

      private def listed(item : Passed) : String
        source = item.defaulted ? " from the default" : ""
        "- `#{item.where}` #{shown(item.value)}#{source}"
      end

      private def unknown_within?(value : Resolve::Resolution) : Bool
        case value
        in Resolve::Unknown  then true
        in Resolve::TypeVar  then false
        in Resolve::MetaRef  then unknown_within?(value.of)
        in Resolve::UnionRef then value.members.any? { |member| unknown_within?(member) }
        in Resolve::TypeRef  then value.arguments.any? { |argument| unknown_within?(argument) }
        end
      end
    end
  end
end
