require "wait_group"

module Heucristic
  module Fibers
    extend self

    WORKER_THREADS = System.cpu_count.to_i

    enum Name
      Reader
      Indexer
      Macros
      Compiler
      Sweep
      Check
    end

    @@parallel_contexts = Hash(Name, Fiber::ExecutionContext::Parallel).new

    def detach(name : Name, &block : ->) : Nil
      spawn(name: name.to_s) { exit_on_exception(block) }
    end

    def parallel(name : Name, workers : Int32, &block : Int32 ->) : Nil
      context = parallel_context(name)
      waiting = WaitGroup.new(workers)
      failures = Channel(Exception).new(workers)

      workers.times do |worker|
        launch(context, waiting, worker, failures, block)
      end

      waiting.wait

      select
      when error = failures.receive
        raise error
      else
      end
    end

    private def parallel_context(name : Name) : Fiber::ExecutionContext::Parallel
      @@parallel_contexts[name] ||= Fiber::ExecutionContext::Parallel.new(name.to_s, WORKER_THREADS)
    end

    private def launch(
      context : Fiber::ExecutionContext::Parallel,
      waiting : WaitGroup,
      worker : Int32,
      failures : Channel(Exception),
      block : Int32 ->,
    ) : Nil
      context.spawn do
        outcome = contain { block.call(worker) }
        failures.send(outcome) if outcome.is_a?(Exception)
      ensure
        waiting.done
      end
    end

    private def exit_on_exception(block : ->) : Nil
      outcome = contain { block.call }

      return unless outcome.is_a?(Exception)
      outcome.inspect_with_backtrace(STDERR)
      exit 1
    end

    private def contain(& : -> T) : T | Exception forall T
      yield
    rescue error
      error
    end
  end
end
