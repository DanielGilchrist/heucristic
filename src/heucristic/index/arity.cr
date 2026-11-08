module Heucristic
  module Index
    record Arity, required : Int32, optional : Int32, splat : Bool do
      def self.of(node : Crystal::Def | Crystal::Macro) : Arity
        of(node.args, node.splat_index)
      end

      def self.of(args : Array(Crystal::Arg), splat_index : Int32?) : Arity
        positional = splat_index ? args[0, splat_index] : args
        required = positional.count(&.default_value.nil?)
        variadic = !splat_index.nil? && !args[splat_index].name.empty?
        new(required, positional.size - required, variadic)
      end

      def self.anything : Arity
        new(0, 0, true)
      end

      def accepts?(count : Int32) : Bool
        count >= required && (splat || count <= required + optional)
      end

      def expected : String
        return "#{required}+" if splat
        return required.to_s if optional.zero?

        "#{required}..#{required + optional}"
      end
    end
  end
end
