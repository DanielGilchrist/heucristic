require "./restriction"
require "./evident"
require "./parameter_kind"

module Heucristic
  module Index
    record Parameter,
      name : String,
      external_name : String,
      restriction : Restriction,
      default : String?,
      kind : ParameterKind,
      default_type : Syntax::Type? = nil do
      def self.from(arg : Crystal::Arg, kind : ParameterKind) : Parameter
        default = arg.default_value
        evident = default ? Evident.type(default) : Evident::NotEvident.new
        new(
          name: arg.name,
          external_name: arg.external_name,
          restriction: Restrictions.of(arg.restriction),
          default: default.try(&.to_s),
          kind: kind,
          default_type: evident.is_a?(Syntax::Type) ? evident : nil,
        )
      end

      def identity : String
        String.build do |io|
          write_prefix(io)
          io << external_name
          Restrictions.write(io, restriction) unless kind.block?
        end
      end

      def same_identity?(other : Parameter) : Bool
        return false unless kind.same_prefix?(other.kind) && external_name == other.external_name

        kind.block? || restriction == other.restriction
      end

      def rendered(restriction_text : String?) : Parameter
        return self unless restriction_text

        rendered = Syntax::Named.new([restriction_text], false)
        Parameter.new(name, external_name, rendered, default, kind, default_type)
      end

      def unrestricted_identity : String
        String.build do |io|
          write_prefix(io)
          io << external_name
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
