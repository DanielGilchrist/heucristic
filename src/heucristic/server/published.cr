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

      def checks(uri : String, diagnostics : Array(LSProtocol::Diagnostic)) : Nil
        if diagnostics.empty?
          @checks.delete(uri)
        else
          @checks[uri] = diagnostics
        end
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
    end
  end
end
