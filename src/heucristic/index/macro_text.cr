require "compiler/crystal/syntax"
require "semantic_version"

module Heucristic
  module Index
    module MacroText
      extend self

      record Undecidable, reason : String

      FLAG_NAMES = {
        "darwin", "linux", "unix", "windows", "win32", "wasm32", "x86_64", "aarch64", "bits64",
        "bits32", "freebsd", "openbsd", "netbsd", "dragonfly", "bsd", "android", "solaris", "musl",
        "gnu", "interpreted", "docs", "preview_mt", "execution_context", "without_openssl",
        "without_zlib", "without_iconv", "gc_none", "static", "release", "debug",
      }

      {% begin %}
        HOST_FLAGS = {
          {% for name in FLAG_NAMES %}
            { {{ name }}, {{ flag?(name.id) }} },
          {% end %}
        }
      {% end %}

      def expand(node : Crystal::MacroIf) : String | Undecidable
        taken = evaluate(node.cond)
        return taken if taken.is_a?(Undecidable)

        branch = taken ? node.then : node.else
        text(branch)
      end

      def flag?(name : String) : Bool
        found = HOST_FLAGS.find { |entry| entry[0] == name }
        found ? found[1] : false
      end

      private def text(node : Crystal::ASTNode) : String | Undecidable
        case node
        when Crystal::MacroLiteral then node.value
        when Crystal::Nop          then ""
        when Crystal::MacroIf      then expand(node)
        when Crystal::Expressions
          String.build do |io|
            node.expressions.each do |piece|
              part = text(piece)
              return part if part.is_a?(Undecidable)
              io << part
            end
          end
        else
          Undecidable.new("#{node.class.name} inside a macro body")
        end
      end

      private def evaluate(cond : Crystal::ASTNode) : Bool | Undecidable
        case cond
        when Crystal::BoolLiteral then cond.value
        when Crystal::Not
          inner = evaluate(cond.exp)
          inner.is_a?(Bool) ? !inner : inner
        when Crystal::And
          both(evaluate(cond.left), evaluate(cond.right)) { |left, right| left && right }
        when Crystal::Or
          both(evaluate(cond.left), evaluate(cond.right)) { |left, right| left || right }
        when Crystal::Call then call(cond)
        else                    Undecidable.new(cond.to_s)
        end
      end

      private def both(
        left : Bool | Undecidable,
        right : Bool | Undecidable,
        & : Bool, Bool -> Bool
      ) : Bool | Undecidable
        return left if left.is_a?(Undecidable)
        return right if right.is_a?(Undecidable)

        yield left, right
      end

      private def call(cond : Crystal::Call) : Bool | Undecidable
        if cond.name == "flag?" && cond.obj.nil?
          flag = cond.args[0]?
          return flag?(flag.value) if flag.is_a?(Crystal::SymbolLiteral)
        end

        obj = cond.obj
        if obj.is_a?(Crystal::Call) && obj.name == "compare_versions" && obj.args.size == 2
          return versions(obj.args[0], obj.args[1], cond.name, cond.args[0]?)
        end

        Undecidable.new(cond.to_s)
      end

      private def versions(
        left : Crystal::ASTNode,
        right : Crystal::ASTNode,
        operator : String,
        against : Crystal::ASTNode?,
      ) : Bool | Undecidable
        a = version_of(left)
        b = version_of(right)
        return Undecidable.new("compare_versions(#{left}, #{right})") unless a && b
        unless against.is_a?(Crystal::NumberLiteral) && against.value == "0"
          return Undecidable.new("compare_versions against #{against}")
        end

        comparison = a <=> b
        case operator
        when ">=" then comparison >= 0
        when ">"  then comparison > 0
        when "<=" then comparison <= 0
        when "<"  then comparison < 0
        when "==" then comparison == 0
        when "!=" then comparison != 0
        else           Undecidable.new("compare_versions #{operator}")
        end
      end

      private def version_constant?(node : Crystal::Path) : Bool
        node.names == ["Crystal", "VERSION"] || node.names == ["VERSION"]
      end

      private def version_of(node : Crystal::ASTNode) : SemanticVersion?
        source = case node
                 when Crystal::StringLiteral then node.value
                 when Crystal::Path
                   version_constant?(node) ? Crystal::VERSION : nil
                 end
        return unless source

        SemanticVersion.parse(source)
      rescue ArgumentError
        nil
      end
    end
  end
end
