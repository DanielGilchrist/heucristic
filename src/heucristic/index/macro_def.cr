require "compiler/crystal/syntax"
require "../document/span"
require "./owner"
require "./parameter"
require "./arity"
require "./argument_check"
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
        named = call.named_args.try(&.map(&.name)) || Array(String).new
        check = ArgumentCheck.new(parameters, call.args.size, named)
        return wrong_arity(call) if check.overflowing?(arity)

        found = check.complaint
        case found
        in AlreadySpecified, NoParameter then found.to_s
        in MissingArgument               then wrong_arity(call)
        in Nil                           then nil
        end
      end

      private def wrong_arity(call : Crystal::Call) : String
        "wrong number of arguments for macro '#{call.name}' " \
        "(given #{call.args.size}, expected #{arity.expected})"
      end
    end
  end
end
