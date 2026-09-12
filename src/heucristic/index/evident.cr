require "compiler/crystal/syntax"
require "../syntax/type_reader"

module Heucristic
  module Index
    module Evident
      extend self

      record NotEvident

      def type(node : Crystal::ASTNode) : Syntax::Type | NotEvident
        case node
        in Crystal::StringLiteral, Crystal::StringInterpolation then builtin("String")
        in Crystal::CharLiteral                                 then builtin("Char")
        in Crystal::BoolLiteral                                 then builtin("Bool")
        in Crystal::NilLiteral                                  then builtin("Nil")
        in Crystal::SymbolLiteral                               then builtin("Symbol")
        in Crystal::RegexLiteral                                then builtin("Regex")
        in Crystal::NumberLiteral
          builtin(number_type(node.kind))
        in Crystal::Path, Crystal::Generic then metaclass(node)
        in Crystal::Call                   then constructed(node)
        in Crystal::Cast                   then read(node.to)
        in Crystal::NilableCast            then nilable(node.to)
        in Crystal::ArrayLiteral           then collection("Array", node.of)
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
        return NotEvident.new unless target && call.name == "new" && call.block.nil?
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

      private def collection(base : String, of : Crystal::ASTNode?) : Syntax::Type | NotEvident
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
        Syntax::Generic.new(builtin("Hash"), arguments, Array(Syntax::Generic::NamedArgument).new)
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

      private def builtin(name : String) : Syntax::Named
        Syntax::Named.new([name], true)
      end

      private def number_type(kind : Crystal::NumberKind) : String
        case kind
        in .i8?   then "Int8"
        in .i16?  then "Int16"
        in .i32?  then "Int32"
        in .i64?  then "Int64"
        in .i128? then "Int128"
        in .u8?   then "UInt8"
        in .u16?  then "UInt16"
        in .u32?  then "UInt32"
        in .u64?  then "UInt64"
        in .u128? then "UInt128"
        in .f32?  then "Float32"
        in .f64?  then "Float64"
        end
      end
    end
  end
end
