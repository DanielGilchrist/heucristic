require "../index/def"
require "../index/owner"
require "./special"
require "./special_key"

module Heucristic
  module Resolve
    module SpecialLookup
      PAIRS = {
        {SpecialKey.new("Object", :instance, "class"), Special::ObjectClass},
        {SpecialKey.new("Enum", :instance, "value"), Special::EnumValue},
        {SpecialKey.new("Array", :instance, "compact"), Special::ArrayCompact},
        {SpecialKey.new("Proc", :instance, "call"), Special::ProcCall},
        {SpecialKey.new("Tuple", :instance, "first"), Special::TupleFirst},
        {SpecialKey.new("Tuple", :instance, "last"), Special::TupleLast},
        {SpecialKey.new("Tuple", :instance, "first?"), Special::TupleFirstOrNil},
        {SpecialKey.new("Tuple", :instance, "last?"), Special::TupleLastOrNil},
        {SpecialKey.new("Tuple", :instance, "map"), Special::TupleMap},
        {SpecialKey.new("NamedTuple", :instance, "values"), Special::NamedTupleValues},
        {SpecialKey.new("NamedTuple", :instance, "keys"), Special::NamedTupleKeys},
        {SpecialKey.new("Spec::ObjectExtensions", :instance, "should_not"), Special::ShouldNot},
        {SpecialKey.new("Enumerable", :instance, "zip"), Special::EnumerableZip},
        {SpecialKey.new("Enumerable", :instance, "zip?"), Special::EnumerableZipOrNil},
        {SpecialKey.new("Enumerable", :instance, "to_h"), Special::EnumerableToH},
        {SpecialKey.new("Enum", :metaclass, "each"), Special::EnumEach},
        {SpecialKey.new(Index::TopLevel.new, :instance, "loop"), Special::Loop},
      }

      BY_KEY = build

      def self.find(entry : Index::Def) : Special?
        BY_KEY[SpecialKey.new(entry.owner, entry.receiver, entry.name)]?
      end

      def self.build : Hash(SpecialKey, Special)
        by_key = Hash(SpecialKey, Special).new(initial_capacity: PAIRS.size)
        PAIRS.each { |(key, special)| by_key[key] = special }
        by_key
      end
    end
  end
end
