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
