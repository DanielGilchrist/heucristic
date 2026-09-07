require "compiler/crystal/syntax"

module Heucristic
  module Index
    module Signature
      extend self

      def of(node : Crystal::Def) : String
        String.build do |io|
          io << "def "
          if (receiver = node.receiver)
            io << receiver << '.'
          end
          io << node.name
          write_parameters(io, node)
          if (return_type = node.return_type)
            io << " : " << return_type
          end
        end
      end

      private def write_parameters(io : IO, node : Crystal::Def) : Nil
        parts = Array(String).new
        node.args.each_with_index do |arg, index|
          parts << (index == node.splat_index ? "*#{arg}" : arg.to_s)
        end
        if (double_splat = node.double_splat)
          parts << "**#{double_splat}"
        end
        if (block_arg = node.block_arg)
          parts << "&#{block_arg}"
        end
        return if parts.empty?

        io << '(' << parts.join(", ") << ')'
      end
    end
  end
end
