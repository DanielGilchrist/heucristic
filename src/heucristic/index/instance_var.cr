require "../document/span"
require "../syntax/type_reader"

module Heucristic
  module Index
    enum Origin
      Declared
      Assigned
    end

    record InstanceVar,
      name : String,
      owner : String,
      type : Syntax::TypeReader::Outcome,
      path : String,
      name_span : Document::Span,
      origin : Origin
  end
end
