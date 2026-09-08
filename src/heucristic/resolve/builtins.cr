module Heucristic
  module Resolve
    module Builtins
      NAMES = {
        "Object", "Reference", "Value", "Number", "NoReturn", "Void", "Nil", "Bool", "Char",
        "Int", "Int8", "Int16", "Int32", "Int64", "Int128",
        "UInt8", "UInt16", "UInt32", "UInt64", "UInt128",
        "Float", "Float32", "Float64", "Symbol", "Pointer", "Tuple", "NamedTuple", "StaticArray",
        "String", "Class", "Struct", "Enumerable", "Indexable", "Array", "Hash", "Regex", "Range",
        "Slice", "Exception", "Enum", "Proc", "Union", "Crystal",
      }

      def self.includes?(name : String) : Bool
        NAMES.includes?(name)
      end
    end
  end
end
