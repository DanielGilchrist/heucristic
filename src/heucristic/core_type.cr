require "./index/identity"

module Heucristic
  enum CoreType
    Nil
    Bool
    Char
    String
    Symbol
    Regex
    Int8
    Int16
    Int32
    Int64
    Int128
    UInt8
    UInt16
    UInt32
    UInt64
    UInt128
    Float32
    Float64
    NoReturn
    Tuple
    NamedTuple
    Array
    Hash
    Range
    Proc
    Union
    Object
    Class
    Exception
    Indexable
    Enumerable
    Enum
    Struct
    Reference
    Value
    Pointer

    def self.from_name(name : ::String) : CoreType?
      each { |core| return core if core.type_name == name }
      nil
    end

    def widens_to?(target : CoreType) : ::Bool
      return true if self == target

      case self
      in Int8    then target.in?(Int16, Int32, Int64, Int128, Float32, Float64)
      in Int16   then target.in?(Int32, Int64, Int128, Float32, Float64)
      in Int32   then target.in?(Int64, Int128, Float64)
      in Int64   then target.in?(Int128)
      in UInt8   then target.in?(UInt16, UInt32, UInt64, UInt128, Int16, Int32, Int64, Int128)
      in UInt16  then target.in?(UInt32, UInt64, UInt128, Int32, Int64, Int128, Float32, Float64)
      in UInt32  then target.in?(UInt64, UInt128, Int64, Int128, Float64)
      in UInt64  then target.in?(UInt128, Int128)
      in Float32 then target == Float64
      in Int128, UInt128, Float64, Nil, Bool, Char, String, Symbol, Regex, NoReturn, Tuple,
         NamedTuple, Array, Hash, Range, Proc, Union, Object, Class, Exception, Indexable,
         Enumerable, Enum, Struct, Reference, Value, Pointer
        false
      end
    end

    def numeric? : ::Bool
      case self
      in Int8, Int16, Int32, Int64, Int128, UInt8, UInt16, UInt32, UInt64, UInt128, Float32,
         Float64
        true
      in Nil, Bool, Char, String, Symbol, Regex, NoReturn, Tuple, NamedTuple, Array, Hash, Range,
         Proc, Union, Object, Class, Exception, Indexable, Enumerable, Enum, Struct, Reference,
         Value, Pointer
        false
      end
    end

    def identity : Index::Public
      Index::Public.new(type_name)
    end

    def type_name : ::String
      case self
      in CoreType::Nil        then "Nil"
      in CoreType::Bool       then "Bool"
      in CoreType::Char       then "Char"
      in CoreType::String     then "String"
      in CoreType::Symbol     then "Symbol"
      in CoreType::Regex      then "Regex"
      in CoreType::Int8       then "Int8"
      in CoreType::Int16      then "Int16"
      in CoreType::Int32      then "Int32"
      in CoreType::Int64      then "Int64"
      in CoreType::Int128     then "Int128"
      in CoreType::UInt8      then "UInt8"
      in CoreType::UInt16     then "UInt16"
      in CoreType::UInt32     then "UInt32"
      in CoreType::UInt64     then "UInt64"
      in CoreType::UInt128    then "UInt128"
      in CoreType::Float32    then "Float32"
      in CoreType::Float64    then "Float64"
      in CoreType::NoReturn   then "NoReturn"
      in CoreType::Tuple      then "Tuple"
      in CoreType::NamedTuple then "NamedTuple"
      in CoreType::Array      then "Array"
      in CoreType::Hash       then "Hash"
      in CoreType::Range      then "Range"
      in CoreType::Proc       then "Proc"
      in CoreType::Union      then "Union"
      in CoreType::Object     then "Object"
      in CoreType::Class      then "Class"
      in CoreType::Exception  then "Exception"
      in CoreType::Indexable  then "Indexable"
      in CoreType::Enumerable then "Enumerable"
      in CoreType::Enum       then "Enum"
      in CoreType::Struct     then "Struct"
      in CoreType::Reference  then "Reference"
      in CoreType::Value      then "Value"
      in CoreType::Pointer    then "Pointer"
      end
    end
  end
end
