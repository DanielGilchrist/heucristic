struct Atomic(T)
  def swap(value : T, ordering : Ordering = :sequentially_consistent) : T
  end
end
