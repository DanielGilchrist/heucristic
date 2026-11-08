require "compiler/crystal/syntax"
require "./body_facts"
require "./resolution"
require "../syntax/broken"

module Heucristic
  module Resolve
    class Memos
      getter facts : Hash(UInt64, BodyFacts)
      getter typed_values : Hash(UInt64, Resolution)
      getter call_results : Hash(Receiver::CallKey, Receiver::CachedCall)
      getter block_inputs : Hash({UInt64, Int32}, Resolution)
      getter yield_scopes : Hash(UInt64, Resolution | Receiver::Unscoped)
      getter expanded : Hash(UInt64, MacroExpansions::Expanded | Syntax::Broken)
      getter macro_assigned : Hash(UInt64, Hash(String, String))

      def initialize : Nil
        @exit_answers = Hash(String, Hash(UInt64, Bool)).new
        @facts = Hash(UInt64, BodyFacts).new
        @typed_values = Hash(UInt64, Resolution).new
        @call_results = Hash(Receiver::CallKey, Receiver::CachedCall).new
        @block_inputs = Hash({UInt64, Int32}, Resolution).new
        @yield_scopes = Hash(UInt64, Resolution | Receiver::Unscoped).new
        @expanded = Hash(UInt64, MacroExpansions::Expanded | Syntax::Broken).new
        @macro_assigned = Hash(UInt64, Hash(String, String)).new
      end

      def exit_answers(filename : String) : Hash(UInt64, Bool)
        @exit_answers[filename] ||= Hash(UInt64, Bool).new
      end

      def clear : Nil
        @exit_answers.clear
        clear_nodes
      end

      def forget(path : String) : Nil
        @exit_answers.delete(path)
        clear_nodes
      end

      private def clear_nodes : Nil
        @facts.clear
        @typed_values.clear
        @call_results.clear
        @block_inputs.clear
        @yield_scopes.clear
        @expanded.clear
        @macro_assigned.clear
      end
    end
  end
end
