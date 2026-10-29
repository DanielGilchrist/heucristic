require "lsprotocol"

module Heucristic
  module Server
    class Published
      alias Batch = Hash(String, Array(LSProtocol::Diagnostic))

      def initialize : Nil
        @syntax = Batch.new
        @checks = Batch.new
        @compiler = Batch.new
      end

      def syntax(uri : String, diagnostics : Array(LSProtocol::Diagnostic)) : Nil
        @syntax[uri] = diagnostics
      end

      def checks(uri : String, diagnostics : Array(LSProtocol::Diagnostic)) : Bool
        previous = @checks[uri]?
        if diagnostics.empty?
          @checks.delete(uri)
          return !previous.nil?
        end

        @checks[uri] = diagnostics
        previous.nil? || !same?(previous, diagnostics)
      end

      def compiler(batch : Batch) : Array(String)
        touched = @compiler.keys | batch.keys
        @compiler = batch
        touched
      end

      def forget(uri : String) : Nil
        @syntax.delete(uri)
        @checks.delete(uri)
      end

      def for(uri : String) : Array(LSProtocol::Diagnostic)
        errors = @compiler[uri]? || Array(LSProtocol::Diagnostic).new
        warnings = (@checks[uri]? || Array(LSProtocol::Diagnostic).new).reject do |warning|
          errors.any? { |error| error.range.start.line == warning.range.start.line }
        end
        (@syntax[uri]? || Array(LSProtocol::Diagnostic).new) + errors + warnings
      end

      private def same?(
        previous : Array(LSProtocol::Diagnostic),
        current : Array(LSProtocol::Diagnostic),
      ) : Bool
        return false unless previous.size == current.size

        previous.zip(current).all? do |before, after|
          before.message == after.message && before.range == after.range
        end
      end
    end
  end
end
