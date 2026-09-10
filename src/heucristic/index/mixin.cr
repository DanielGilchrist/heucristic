require "../syntax/type_reader"
require "./mixin_kind"

module Heucristic
  module Index
    record Mixin,
      owner : String,
      kind : MixinKind,
      target : Syntax::TypeReader::Outcome,
      path : String
  end
end
