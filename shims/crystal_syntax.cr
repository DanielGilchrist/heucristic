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

class Crystal::ASTNode
  def transform(transformer) : Crystal::ASTNode
  end

  def name_location : Nil
  end
end

class Crystal::Call
  def name_size : Int32
  end
end

class Crystal::Path
  def self.global(names) : Crystal::Path
  end
end

class Crystal::Lexer
  def filename=(filename) : typeof(filename)
  end
end

class Crystal::Parser
  def wants_doc=(@wants_doc : Bool) : Bool
  end
end
