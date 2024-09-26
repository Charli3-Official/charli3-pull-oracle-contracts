# odv-multisig-charli3-oracle-onchain

Design and architecture for Charli3 ODV multisig oracle are described in this [doc](https://charli3io.atlassian.net/wiki/spaces/CHARLI3/pages/407502849/ODV+Multisig+Oracle). Flowcharts that were used in confluence document are uploaded to `docs-media` folder. See also presentation [slides](https://docs.google.com/presentation/d/1xGFmgowJRyg4N8WpRLgPo1wIYawi8ueyj04bHnZjhLs/edit?usp=sharing) where that idea was first described.

## Aiken usage

Write validators in the `validators` folder, and supporting functions in the `lib` folder using `.ak` as a file extension.

```aiken
validator my_first_validator {
  spend(_datum: Option<Data>, _redeemer: Data, _output_reference: Data, _context: Data) {
    True
  }
}
```

### Building

```sh
aiken build
```

### Configuring

**aiken.toml**
```toml
[config.default]
network_id = 41
```

Or, alternatively, write conditional environment modules under `env`.

### Testing

You can write tests in any module using the `test` keyword. For example:

```aiken
use config

test foo() {
  config.network_id + 1 == 42
}
```

To run all tests, simply do:

```sh
aiken check
```

To run only tests matching the string `foo`, do:

```sh
aiken check -m foo
```

### Documentation

If you're writing a library, you might want to generate an HTML documentation for it.

Use:

```sh
aiken docs
```

### Resources

Find more on the [Aiken's user manual](https://aiken-lang.org).

Simply install latest version of aiken (change version tag) `nix profile install github:aiken-lang/aiken/v1.1.3#aiken`.
