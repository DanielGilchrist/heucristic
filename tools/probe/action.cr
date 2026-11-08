require "./invalid"

module Probe
  record Hover
  record Definition
  record Both
  record References
  record Complete
  record Symbols
  record Rename, name : String
  record Workspace, query : String

  alias Action = Hover | Definition | Both | References | Complete | Symbols | Rename | Workspace

  module Actions
    extend self

    def parse(text : String) : Action | Invalid
      case text
      when "hover"      then Hover.new
      when "definition" then Definition.new
      when "both"       then Both.new
      when "references" then References.new
      when "complete"   then Complete.new
      when "symbols"    then Symbols.new
      else
        if text.starts_with?("rename:")
          Rename.new(text.lchop("rename:"))
        elsif text.starts_with?("workspace:")
          Workspace.new(text.lchop("workspace:"))
        else
          Invalid.new
        end
      end
    end
  end
end
