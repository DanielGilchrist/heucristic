require "compiler/crystal/syntax"
require "./parameter"

module Heucristic
  module Index
    module Signature
      extend self

      def of(node : Crystal::Def) : String
        render(
          node.receiver.try(&.to_s), node.name, parameters(node), Restrictions.of(node.return_type)
        )
      end

      def parameters(node : Crystal::Def) : Array(Parameter)
        parameters = Array(Parameter).new(node.args.size + 2)
        splat_index = node.splat_index
        node.args.each_with_index do |arg, index|
          kind = if splat_index.nil? || index < splat_index
                   ParameterKind::Positional
                 elsif index == splat_index
                   ParameterKind::Splat
                 else
                   ParameterKind::Keyword
                 end
          next if kind.splat? && arg.name.empty?

          parameters << Parameter.from(arg, kind)
        end
        if (double_splat = node.double_splat)
          parameters << Parameter.from(double_splat, :double_splat)
        end
        if (block = node.block_arg)
          parameters << Parameter.from(block, :block)
        end
        parameters
      end

      def render(
        receiver : String?,
        name : String,
        parameters : Array(Parameter),
        return_type : Restriction,
      ) : String
        render(receiver, name, parameters) { |io| Restrictions.write(io, return_type) }
      end

      def render(
        receiver : String?,
        name : String,
        parameters : Array(Parameter),
        & : IO ->
      ) : String
        String.build do |io|
          io << "def "
          io << receiver << '.' if receiver
          io << name
          unless parameters.empty?
            io << '('
            parameters.join(io, ", ")
            io << ')'
          end
          yield io
        end
      end
    end
  end
end
