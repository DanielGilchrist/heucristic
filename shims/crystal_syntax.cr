class Crystal::ASTNode
  def accept(visitor) : Nil
  end

  def at(location : Location?) : self
  end

  def at(node : ASTNode) : self
  end
end

class Crystal::NilableCast
  def to : Crystal::ASTNode
  end
end

class Crystal::Parser
  def parse : Crystal::ASTNode
  end
end

class Crystal::Location
  def line_number : Int32
  end

  def column_number : Int32
  end

  def filename : String | Crystal::VirtualFile | Nil
  end
end
