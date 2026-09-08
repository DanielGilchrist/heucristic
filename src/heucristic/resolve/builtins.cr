module Heucristic
  module Resolve
    module Builtins
      SUPERCLASSES = {
        {"Object", ""}, {"Reference", "Object"}, {"Value", "Object"}, {"Number", "Value"},
        {"NoReturn", ""}, {"Void", ""}, {"Nil", "Value"}, {"Bool", "Value"}, {"Char", "Value"},
        {"Int", "Number"}, {"Int8", "Int"}, {"UInt8", "Int"}, {"Int16", "Int"}, {"UInt16", "Int"},
        {"Int32", "Int"}, {"UInt32", "Int"}, {"Int64", "Int"}, {"UInt64", "Int"}, {"Int128", "Int"},
        {"UInt128", "Int"}, {"Float", "Number"}, {"Float32", "Float"}, {"Float64", "Float"},
        {"Symbol", "Value"}, {"Pointer", "Value"}, {"Tuple", "Value"}, {"NamedTuple", "Value"},
        {"StaticArray", "Value"}, {"String", "Reference"}, {"Class", "Value"}, {"Struct", "Value"},
        {"Enumerable", ""}, {"Indexable", ""}, {"Array", "Reference"}, {"Hash", "Reference"},
        {"Regex", "Reference"}, {"Range", "Struct"}, {"Slice", "Struct"},
        {"Exception", "Reference"},
        {"Enum", "Value"}, {"Proc", "Value"}, {"Union", "Value"}, {"Crystal", ""},
      }

      def self.includes?(name : String) : Bool
        SUPERCLASSES.any? { |entry| entry[0] == name }
      end

      def self.superclass(name : String) : String
        SUPERCLASSES.find({"", ""}) { |entry| entry[0] == name }[1]
      end
    end
  end
end
