struct Range(B, E)
  def map(&block : B -> U) : Array(U) forall U
  end
end
