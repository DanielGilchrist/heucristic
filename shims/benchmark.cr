module Benchmark
  def ips(calculation : Time::Span = 5.seconds, warmup : Time::Span = 2.seconds, interactive : Bool = STDOUT.tty?, &) : Benchmark::IPS::Job
  end

  def ips(calculation = 5, warmup = 2, interactive = STDOUT.tty?, &) : Benchmark::IPS::Job
  end
end
