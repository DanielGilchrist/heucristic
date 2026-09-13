require "compiler/crystal/syntax"

module Heucristic
  module Resolve
    enum Precision
      Exact
      Bound

      def self.of(node : Crystal::ASTNode?) : Precision
        case node
        in Nil, Crystal::Nop, Crystal::InstanceVar, Crystal::ClassVar,
           Crystal::NilLiteral, Crystal::BoolLiteral, Crystal::NumberLiteral, Crystal::CharLiteral,
           Crystal::StringLiteral, Crystal::StringInterpolation, Crystal::SymbolLiteral,
           Crystal::RegexLiteral, Crystal::ArrayLiteral, Crystal::HashLiteral,
           Crystal::TupleLiteral, Crystal::NamedTupleLiteral, Crystal::ProcLiteral
          Exact
        in Crystal::Expressions then of(node.expressions.last?)
        in Crystal::Assign      then of(node.value)
        in Crystal::If, Crystal::Unless
          both(of(node.then), of(node.else))
        in Crystal::ASTNode then Bound
        end
      end

      def self.both(left : Precision, right : Precision) : Precision
        left.exact? && right.exact? ? Exact : Bound
      end
    end
  end
end
