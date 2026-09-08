require "./restriction"

module Heucristic
  module Index
    enum ParameterKind
      Positional
      Splat
      Keyword
      DoubleSplat
      Block
    end

    record Parameter,
      name : String,
      external_name : String,
      restriction : Restriction,
      default : String?,
      kind : ParameterKind do
      def self.from(arg : Crystal::Arg, kind : ParameterKind) : Parameter
        new(
          name: arg.name,
          external_name: arg.external_name,
          restriction: Restrictions.of(arg.restriction),
          default: arg.default_value.try(&.to_s),
          kind: kind,
        )
      end

      def identity : String
        String.build do |io|
          write_prefix(io)
          io << external_name
          Restrictions.write(io, restriction) unless kind.block?
        end
      end

      def to_s(io : IO) : Nil
        write_prefix(io)
        io << external_name
        io << ' ' << name if external_name != name
        Restrictions.write(io, restriction)
        return unless (value = default)

        io << " = " << value
      end

      private def write_prefix(io : IO) : Nil
        case kind
        in .positional?, .keyword? then nil
        in .splat?                 then io << '*'
        in .double_splat?          then io << "**"
        in .block?                 then io << '&'
        end
      end
    end
  end
end
