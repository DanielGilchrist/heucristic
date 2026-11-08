module Random
  def self.new(seed, sequence = 0_u64) : Random::PCG32
  end

  def self.new : Random::PCG32
  end
end
