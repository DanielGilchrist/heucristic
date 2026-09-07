module Heucristic
  module Index
    record Arity, required : Int32, optional : Int32, splat : Bool do
      def self.of(node : Crystal::Def) : Arity
        positional = (splat_index = node.splat_index) ? node.args[0, splat_index] : node.args
        required = positional.count(&.default_value.nil?)
        new(required, positional.size - required, !node.splat_index.nil?)
      end

      def accepts?(count : Int32) : Bool
        count >= required && (splat || count <= required + optional)
      end
    end
  end
end
