require "./mixin"
require "./macro_target"

module Heucristic
  module Index
    module MixinOrder
      record Unordered, mixins : Array(Mixin)

      alias Declared = Array(Mixin) | Unordered

      def self.declared(mixins : Array(Mixin), kind : MixinKind) : Declared
        wanted = mixins.select(&.kind.==(kind))
        compiled = wanted.select { |mixin| MacroTarget.generated?(mixin.path) }
        return by_compiler(compiled) unless compiled.empty?

        by_source(wanted)
      end

      private def self.by_compiler(compiled : Array(Mixin)) : Declared
        per_path = compiled.group_by(&.path)
        sequences = per_path.values.map { |group| group.map(&.target) }.uniq!
        return Unordered.new(compiled) if sequences.size > 1

        first_occurrences(compiled)
      end

      private def self.by_source(wanted : Array(Mixin)) : Declared
        paths = wanted.map(&.path).uniq!
        return first_occurrences(wanted) if paths.size < 2 || wanted.map(&.target).uniq!.size < 2

        Unordered.new(wanted)
      end

      private def self.first_occurrences(mixins : Array(Mixin)) : Array(Mixin)
        seen = Array(Syntax::TypeReader::Outcome).new(mixins.size)
        mixins.select do |mixin|
          next false if seen.includes?(mixin.target)

          seen << mixin.target
          true
        end
      end
    end
  end
end
