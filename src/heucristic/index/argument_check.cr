require "./arity"
require "./parameter"
require "./argument_complaint"

module Heucristic
  module Index
    struct ArgumentCheck
      @positional : Array(Parameter)

      def initialize(
        @parameters : Array(Parameter),
        @given : Int32,
        @named : Array(String),
      ) : Nil
        @positional = @parameters.select(&.kind.positional?)
      end

      def overflowing?(arity : Arity) : Bool
        @given > @positional.size && !arity.splat
      end

      def complaint : ArgumentComplaint?
        accepts_any = @parameters.any?(&.kind.double_splat?)
        @named.each do |name|
          index = @positional.index(&.external_name.==(name))
          return AlreadySpecified.new(name) if index && index < @given
          next if index || @parameters.any? { |parameter| keyword_named?(parameter, name) }
          return NoParameter.new(name) unless accepts_any
        end
        @parameters.each do |parameter|
          next unless parameter.kind.keyword? && parameter.default.nil?
          next if @named.includes?(parameter.external_name)

          return MissingArgument.new(parameter.external_name)
        end
        @positional.each_with_index do |parameter, index|
          next if index < @given || parameter.default || @named.includes?(parameter.external_name)

          return MissingArgument.new(parameter.external_name)
        end
        nil
      end

      private def keyword_named?(parameter : Parameter, name : String) : Bool
        parameter.kind.keyword? && parameter.external_name == name
      end
    end
  end
end
