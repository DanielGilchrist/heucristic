require "compiler/crystal/syntax"
require "./version_comparison"
require "semantic_version"
require "../crystal_version"
require "../document/point"

module Heucristic
  module Index
    module MacroText
      extend self

      record Undecidable, reason : String
      record Expansion, text : String, at : Crystal::Location

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

      def expand(
        node : Crystal::MacroIf,
        version : CrystalVersion::Detected,
      ) : Expansion | Undecidable
        taken = evaluate(node.cond, version)
        return taken if taken.is_a?(Undecidable)

        expansion(node, taken ? node.then : node.else, nil, version)
      end

      def expand_at(
        node : Crystal::MacroIf,
        point : Document::Point,
        version : CrystalVersion::Detected,
      ) : Expansion | Undecidable
        return expansion(node, node.then, point, version) if holds?(node.then, point)
        return expansion(node, node.else, point, version) if holds?(node.else, point)

        expand(node, version)
      end

      def flag?(name : String) : Bool
        found = HOST_FLAGS.find { |entry| entry[0] == name }
        found ? found[1] : false
      end

      private def expansion(
        node : Crystal::MacroIf,
        branch : Crystal::ASTNode,
        point : Document::Point?,
        version : CrystalVersion::Detected,
      ) : Expansion | Undecidable
        expanded = text(branch, point, version)
        return expanded if expanded.is_a?(Undecidable)

        at = start_of(branch) || node.location
        return Undecidable.new("a macro region without a location") unless at

        Expansion.new(expanded, at)
      end

      private def holds?(branch : Crystal::ASTNode, point : Document::Point) : Bool
        from = branch.location
        to = branch.end_location
        return false unless from && to

        point >= Document::Point.from(from) && point < Document::Point.from(to)
      end

      private def start_of(node : Crystal::ASTNode) : Crystal::Location?
        first = node.is_a?(Crystal::Expressions) ? node.expressions.first? : node
        first.try(&.location)
      end

      private def text(
        node : Crystal::ASTNode,
        point : Document::Point?,
        version : CrystalVersion::Detected,
      ) : String | Undecidable
        case node
        in Crystal::MacroLiteral then node.value
        in Crystal::Nop          then ""
        in Crystal::MacroIf
          inner = point ? expand_at(node, point, version) : expand(node, version)
          inner.is_a?(Undecidable) ? inner : inner.text
        in Crystal::Expressions
          String.build do |io|
            node.expressions.each do |piece|
              part = text(piece, point, version)
              return part if part.is_a?(Undecidable)
              io << part
            end
          end
        in Crystal::ASTNode
          Undecidable.new("#{node.class.name} inside a macro body")
        end
      end

      private def evaluate(
        cond : Crystal::ASTNode,
        version : CrystalVersion::Detected,
      ) : Bool | Undecidable
        case cond
        in Crystal::BoolLiteral then cond.value
        in Crystal::Not
          inner = evaluate(cond.exp, version)
          inner.is_a?(Bool) ? !inner : inner
        in Crystal::And
          both(evaluate(cond.left, version), evaluate(cond.right, version)) do |left, right|
            left && right
          end
        in Crystal::Or
          both(evaluate(cond.left, version), evaluate(cond.right, version)) do |left, right|
            left || right
          end
        in Crystal::Call then call(cond, version)
        in Crystal::ASTNode
          Undecidable.new(cond.to_s)
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

      private def call(
        cond : Crystal::Call,
        version : CrystalVersion::Detected,
      ) : Bool | Undecidable
        if cond.name == "flag?" && cond.obj.nil?
          flag = cond.args[0]?
          return flag?(flag.value) if flag.is_a?(Crystal::SymbolLiteral)
        end

        obj = cond.obj
        if obj.is_a?(Crystal::Call) && obj.name == "compare_versions" && obj.args.size == 2
          return versions(obj.args[0], obj.args[1], cond.name, cond.args[0]?, version)
        end

        Undecidable.new(cond.to_s)
      end

      private def versions(
        left : Crystal::ASTNode,
        right : Crystal::ASTNode,
        operator : String,
        against : Crystal::ASTNode?,
        installed : CrystalVersion::Detected,
      ) : Bool | Undecidable
        a = version_of(left, installed)
        b = version_of(right, installed)
        return Undecidable.new("compare_versions(#{left}, #{right})") unless a && b
        unless against.is_a?(Crystal::NumberLiteral) && against.value == "0"
          return Undecidable.new("compare_versions against #{against}")
        end

        wanted = VersionComparison.from_operator(operator)
        return Undecidable.new("compare_versions #{operator}") unless wanted

        wanted.holds?(a <=> b)
      end

      private def version_constant?(node : Crystal::Path) : Bool
        node.names == ["Crystal", "VERSION"] || node.names == ["VERSION"]
      end

      private def version_of(
        node : Crystal::ASTNode,
        installed : CrystalVersion::Detected,
      ) : SemanticVersion?
        case node
        in Crystal::StringLiteral then literal_version(node.value)
        in Crystal::Path          then version_constant?(node) ? known(installed) : nil
        in Crystal::ASTNode       then nil
        end
      end

      private def known(installed : CrystalVersion::Detected) : SemanticVersion?
        case installed
        in CrystalVersion::Known   then installed.value
        in CrystalVersion::Unknown then nil
        end
      end

      private def literal_version(source : String) : SemanticVersion?
        SemanticVersion.parse(source)
      rescue ArgumentError
        nil
      end
    end
  end
end
