require "../../src/heucristic/index/identity"
require "../../src/heucristic/resolve/resolution"

def public_type(name : String) : Heucristic::Index::Public
  Heucristic::Index::Public.new(name)
end

def private_type(name : String, path : String) : Heucristic::Index::FilePrivate
  Heucristic::Index::FilePrivate.new(name, path)
end

def type_ref(identity : Heucristic::Index::Identity) : Heucristic::Resolve::TypeRef
  Heucristic::Resolve::TypeRef.new(identity, Array(Heucristic::Resolve::Resolution).new)
end

def type_ref(name : String) : Heucristic::Resolve::TypeRef
  type_ref(public_type(name))
end

def call_shape(
  name : String,
  given : Int32,
  block : Bool,
  types : Array(Heucristic::Resolve::Resolution) = Array(Heucristic::Resolve::Resolution).new,
  named : Array(String) = Array(String).new,
  implicit : Bool = false,
  caller_path : String? = nil,
) : Heucristic::Resolve::Methods::CallShape
  arguments = types.map do |type|
    Heucristic::Resolve::Methods::CallShape::Argument.new(type, :bound)
  end
  bindings = named.map do |label|
    Heucristic::Resolve::Binding.new(label, Heucristic::Resolve::Unknown.new(:unsupported, "named"))
  end
  Heucristic::Resolve::Methods::CallShape.new(
    name, given, block, arguments, bindings, implicit, caller_path
  )
end
