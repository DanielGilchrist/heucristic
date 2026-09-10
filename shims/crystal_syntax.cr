class Crystal::ASTNode
  def accept(visitor) : Nil
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
