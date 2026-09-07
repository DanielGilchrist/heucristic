require "ameba"
require "ameba/cli/cmd"

Fiber::ExecutionContext
  .default
  .resize(Fiber::ExecutionContext.default_workers_count)

exit Ameba::CLI.run ? 0 : 1
