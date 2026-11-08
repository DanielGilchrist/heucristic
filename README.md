# heucristic

TODO: Write a description here

## Installation

TODO: Write installation instructions here

## Usage

TODO: Write usage instructions here

## Project shims

The server never infers a return type. When a def has no return restriction the answer is
"unknown", including defs in your own code and in shards. To type one anyway, put a `shims/`
directory next to `shard.yml` that reopens the type and restates the def with a return
restriction and an empty body:

```crystal
# shims/greeter.cr
class Greeter
  def greet(name : String) : String
  end
end
```

A shim matches a def by owner, name and parameters (defaults and block restrictions are
ignored), and is used only when the real def has no return restriction. It never adds a method.
Shims are indexed after the ones built into the server, so a project shim wins over an
embedded one for the same def. `bin/score <project>` reads the same directory.

## Development

TODO: Write development instructions here

## Contributing

1. Fork it (<https://github.com/your-github-user/heucristic/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Daniel Gilchrist](https://github.com/your-github-user) - creator and maintainer
