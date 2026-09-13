module Spec::Methods
  def fail(msg, file = __FILE__, line = __LINE__) : NoReturn
  end
end

module Spec::Expectations
  def eq(value : T) : Spec::EqualExpectation(T) forall T
  end

  def be(value : T) : Spec::BeExpectation(T) forall T
  end

  def be_true : Spec::EqualExpectation(Bool)
  end

  def be_false : Spec::EqualExpectation(Bool)
  end

  def be_truthy : Spec::BeTruthyExpectation
  end

  def be_falsey : Spec::BeFalseyExpectation
  end

  def be_nil : Spec::BeNilExpectation
  end

  def be_close(expected : T, delta : D) : Spec::CloseExpectation(T, D) forall T, D
  end

  def be : Spec::Be.class
  end

  def match(value : T) : Spec::MatchExpectation(T) forall T
  end

  def contain(expected : T) : Spec::ContainExpectation(T) forall T
  end

  def start_with(expected : T) : Spec::StartWithExpectation(T) forall T
  end

  def end_with(expected : T) : Spec::EndWithExpectation(T) forall T
  end

  def be_empty : Spec::BeEmptyExpectation
  end
end
