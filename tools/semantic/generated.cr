require "compiler/requires"

module Semantic
  record Generated, definition : Crystal::Def, metaclass : Bool, file : Crystal::VirtualFile
end
