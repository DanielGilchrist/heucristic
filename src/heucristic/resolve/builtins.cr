module Heucristic
  module Resolve
    module Builtins
      record NoSuperclass

      ROOTS = {"Object", "NoReturn", "Void", "Enumerable", "Indexable", "Crystal"}

      SUPERCLASSES = {
        {"Reference", "Object"}, {"Value", "Object"}, {"Number", "Value"}, {"Nil", "Value"},
        {"Bool", "Value"}, {"Char", "Value"}, {"Int", "Number"}, {"Int8", "Int"}, {"UInt8", "Int"},
        {"Int16", "Int"}, {"UInt16", "Int"}, {"Int32", "Int"}, {"UInt32", "Int"}, {"Int64", "Int"},
        {"UInt64", "Int"}, {"Int128", "Int"}, {"UInt128", "Int"}, {"Float", "Number"},
        {"Float32", "Float"}, {"Float64", "Float"}, {"Symbol", "Value"}, {"Pointer", "Value"},
        {"Tuple", "Value"}, {"NamedTuple", "Value"}, {"StaticArray", "Value"},
        {"String", "Reference"}, {"Class", "Value"}, {"Struct", "Value"}, {"Array", "Reference"},
        {"Hash", "Reference"}, {"Regex", "Reference"}, {"Range", "Struct"}, {"Slice", "Struct"},
        {"Exception", "Reference"}, {"Enum", "Value"}, {"Proc", "Value"}, {"Union", "Value"},
      }

      def self.includes?(name : String) : Bool
        ROOTS.includes?(name) || SUPERCLASSES.any? { |entry| entry[0] == name }
      end

      def self.superclass(name : String) : String | NoSuperclass
        entry = SUPERCLASSES.find { |candidate| candidate[0] == name }
        entry ? entry[1] : NoSuperclass.new
      end
    end
  end
end
