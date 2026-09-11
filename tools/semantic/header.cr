require "compiler/requires"

module Semantic
  module Header
    extend self

    def reopen(type : Crystal::ModuleType) : String
      keyword = case type
                in Crystal::EnumType   then "enum"
                in Crystal::ClassType  then type.struct? ? "struct" : "class"
                in Crystal::ModuleType then "module"
                end
      "#{keyword} ::#{type}"
    end

    def def(definition : Crystal::Def, metaclass : Bool) : String
      header = Crystal::Def.new(
        definition.name,
        definition.args,
        Crystal::Nop.new,
        metaclass ? Crystal::Var.new("self") : nil,
        definition.block_arg,
        definition.return_type,
        false,
        definition.block_arity,
        false,
        definition.splat_index,
        definition.double_splat,
        definition.free_vars,
      )
      header.visibility = definition.visibility
      text = header.to_s
      text.ends_with?("\nend") ? text[0...-4] : text
    end
  end
end
