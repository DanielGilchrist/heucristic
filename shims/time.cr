struct Time
  def shift(*, years : Int = 0, months : Int = 0, weeks : Int = 0, days : Int = 0,
            hours : Int = 0, minutes : Int = 0, seconds : Int = 0, nanoseconds : Int = 0) : Time
  end
end

struct Time::Span
  def self.new(*, nanoseconds : Int) : self
  end

  def self.new(*, weeks : Int = 0, days : Int = 0, hours : Int = 0, minutes : Int = 0, seconds : Int = 0, nanoseconds : Int = 0) : self
  end
end
