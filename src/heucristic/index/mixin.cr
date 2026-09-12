require "../syntax/type_reader"
require "./mixin_kind"
require "./owner"

module Heucristic
  module Index
    record Mixin,
      owner : Owner,
      kind : MixinKind,
      target : Syntax::TypeReader::Outcome,
      path : String
  end
end
