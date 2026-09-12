require "compiler/crystal/syntax"
require "../syntax/well_known"
require "../core_type"
require "../syntax/type_reader"

module Heucristic
  module Index
    module Evident
      extend self

      record NotEvident

      def type(node : Crystal::ASTNode) : Syntax::Type | NotEvident
        case node
        in Crystal::StringLiteral, Crystal::StringInterpolation then builtin(:string)
        in Crystal::CharLiteral                                 then builtin(:char)
        in Crystal::BoolLiteral                                 then builtin(:bool)
        in Crystal::NilLiteral                                  then builtin(:nil)
        in Crystal::SymbolLiteral                               then builtin(:symbol)
        in Crystal::RegexLiteral                                then builtin(:regex)
        in Crystal::NumberLiteral
          builtin(number_type(node.kind))
        in Crystal::Path, Crystal::Generic then metaclass(node)
        in Crystal::Call                   then constructed(node)
        in Crystal::Cast                   then read(node.to)
        in Crystal::NilableCast            then nilable(node.to)
        in Crystal::ArrayLiteral           then collection(:array, node.of)
        in Crystal::HashLiteral            then hash(node)
        in Crystal::ProcLiteral            then proc_literal(node.def)
        in Crystal::Expressions
          node.expressions.size == 1 ? type(node.expressions[0]) : NotEvident.new
        in Crystal::ASTNode
          NotEvident.new
        end
      end

      private def constructed(call : Crystal::Call) : Syntax::Type | NotEvident
        target = call.obj
        return NotEvident.new unless target && Syntax::WellKnown::New.named?(call.name)
        return NotEvident.new unless call.block.nil?
        return NotEvident.new unless target.is_a?(Crystal::Path) || target.is_a?(Crystal::Generic)

        read(target)
      end

      private def metaclass(node : Crystal::ASTNode) : Syntax::Type | NotEvident
        inner = read(node)
        return inner if inner.is_a?(NotEvident)

        Syntax::Metaclass.new(inner)
      end

      private def nilable(node : Crystal::ASTNode) : Syntax::Type | NotEvident
        inner = read(node)
        return inner if inner.is_a?(NotEvident)

        Syntax::Nilable.new(inner)
      end

      private def collection(base : CoreType, of : Crystal::ASTNode?) : Syntax::Type | NotEvident
        return NotEvident.new unless of

        element = read(of)
        return element if element.is_a?(NotEvident)

        arguments = [element] of Syntax::Type
        Syntax::Generic.new(builtin(base), arguments, Array(Syntax::Generic::NamedArgument).new)
      end

      private def hash(node : Crystal::HashLiteral) : Syntax::Type | NotEvident
        name = node.name
        return read(name) if name

        of = node.of
        return NotEvident.new unless of

        key = read(of.key)
        return key if key.is_a?(NotEvident)
        value = read(of.value)
        return value if value.is_a?(NotEvident)

        arguments = [key, value] of Syntax::Type
        Syntax::Generic.new(builtin(:hash), arguments, Array(Syntax::Generic::NamedArgument).new)
      end

      private def proc_literal(definition : Crystal::Def) : Syntax::Type | NotEvident
        output = definition.return_type
        return NotEvident.new unless output

        inputs = Array(Syntax::Type).new(definition.args.size)
        definition.args.each do |argument|
          restriction = argument.restriction
          return NotEvident.new unless restriction

          input = read(restriction)
          return input if input.is_a?(NotEvident)

          inputs << input
        end
        result = read(output)
        return result if result.is_a?(NotEvident)

        Syntax::Proc.new(inputs, result)
      end

      private def read(node : Crystal::ASTNode) : Syntax::Type | NotEvident
        type = Syntax::TypeReader.read(node)
        type.is_a?(Syntax::TypeReader::Unsupported) ? NotEvident.new : type
      end

      private def builtin(core : CoreType) : Syntax::Named
        Syntax::Named.of(core)
      end

      private def number_type(kind : Crystal::NumberKind) : CoreType
        case kind
        in .i8?   then CoreType::Int8
        in .i16?  then CoreType::Int16
        in .i32?  then CoreType::Int32
        in .i64?  then CoreType::Int64
        in .i128? then CoreType::Int128
        in .u8?   then CoreType::UInt8
        in .u16?  then CoreType::UInt16
        in .u32?  then CoreType::UInt32
        in .u64?  then CoreType::UInt64
        in .u128? then CoreType::UInt128
        in .f32?  then CoreType::Float32
        in .f64?  then CoreType::Float64
        end
      end
    end
  end
end
