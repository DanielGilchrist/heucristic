require "../syntax/type_reader"

module Heucristic
  module Index
    enum MixinKind
      Include
      Extend
    end

    record Mixin,
      owner : String,
      kind : MixinKind,
      target : Syntax::TypeReader::Outcome,
      path : String
  end
end
