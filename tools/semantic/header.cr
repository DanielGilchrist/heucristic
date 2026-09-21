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

    def declare(type : Crystal::ModuleType) : String
      header = reopen(type)
      return header unless type.is_a?(Crystal::ClassType)

      superclass = type.superclass
      return header unless superclass
      return header if superclass.to_s.in?("Reference", "Struct", "Object", "Value", "Enum")

      "#{header} < ::#{superclass}"
    end

    def macro(definition : Crystal::Macro) : String
      header = Crystal::Macro.new(
        definition.name,
        definition.args,
        Crystal::Nop.new,
        definition.block_arg,
        definition.splat_index,
        definition.double_splat,
      )
      header.to_s.lines.first.chomp
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
