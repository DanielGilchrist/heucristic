require "compiler/crystal/syntax"
require "../document/span"
require "./owner"
require "./parameter"
require "./arity"
require "./macro_effect"

module Heucristic
  module Index
    record MacroDef,
      name : String,
      owner : Owner,
      path : String,
      name_span : Document::Span,
      parameters : Array(Parameter),
      arity : Arity,
      effect : MacroEffect,
      splices_block : Bool do
      def accepts?(call : Crystal::Call) : Bool
        complaint(call).nil?
      end

      def complaint(call : Crystal::Call) : String?
        positional = parameters.select(&.kind.positional?)
        named = call.named_args.try(&.map(&.name)) || Array(String).new
        accepts_any = parameters.any?(&.kind.double_splat?)
        given = call.args.size
        overflow = given > positional.size && !arity.splat
        return wrong_arity(call) if overflow

        named.each do |name|
          index = positional.index(&.external_name.==(name))
          return "argument for parameter '#{name}' already specified" if index && index < given
          next if index || parameters.any? { |parameter| keyword?(parameter, name) }
          return "no parameter named '#{name}'" unless accepts_any
        end
        parameters.each do |parameter|
          next unless parameter.kind.keyword? && parameter.default.nil?
          next if named.includes?(parameter.external_name)

          return wrong_arity(call)
        end
        positional.each_with_index do |parameter, index|
          next if index < given || parameter.default || named.includes?(parameter.external_name)

          return wrong_arity(call)
        end
        nil
      end

      private def wrong_arity(call : Crystal::Call) : String
        "wrong number of arguments for macro '#{call.name}' " \
        "(given #{call.args.size}, expected #{arity.expected})"
      end

      private def keyword?(parameter : Parameter, name : String) : Bool
        parameter.kind.keyword? && parameter.external_name == name
      end
    end
  end
end
