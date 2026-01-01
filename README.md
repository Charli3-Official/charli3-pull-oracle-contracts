# Charli3 Multisig Pull Oracle On-chain

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

For mainnet:

```sh
aiken build
```

For testnets:

```sh
aiken build --env testnet --trace-filter user-defined
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

This command is run on every commit if you install the git hook by running:

```bash
root="$(pwd)" && ln -s "$root/hooks/pre-commit" "$root/.git/hooks/pre-commit"
```

### Resources

Find more on the [Aiken's user manual](https://aiken-lang.org).

Simply install latest version of aiken (change version tag) `nix profile install github:aiken-lang/aiken/v1.1.16#aiken`.

## Validators trace messages and codes

Validators trace messages and codes with their mapping are described here.

To reduce script size we can remove traces altogether, but then it's hard to know where error is coming from, especially when doing debugging in testnets.
Other option is to use short trace and error codes instead of messages, this document describes them.

### Errors

Direct failures that stop evaluation.

* E1 – `oracle_nfts` was invoked outside of a minting context.
* E2 – `oracle_manager` validators expect `spend` purpose and reject anything else.
* E3 – `oracle_manager` received an unsupported redeemer/state transition.
* E4 – `consensus.median` was asked to operate on an empty list.
* E5 – list elements expected in ascending order (used for feed/value ordering checks).
* E6 – feed verification keys must be strictly ascending when iterating.
* E7 – node list must be non-empty when validating feed order.

### Traces

Trace message is added to the list (evaluation context) when evaluation comes to a particular code branch, it will be added on every evaluation failure as well as success.

* T1 – `ScaleToken` mint path (adding fresh Reward/AggState UTxOs).
* T2 – `ScaleToken` burn path (requiring the matching inputs to be consumed).
* T3 – `find_own_protocol_policy_id` extracts the oracle policy id from inputs.
* T4 – `get_current_time` derives the midpoint from the validity range.
* T5 – `auth_by_nft` validates the platform NFT witness.
* T6 – `check_nodes_multisig` verifies node signatures against settings.
* T7 – `spends_protocol_nft_inputs` checks the number of spent oracle NFTs.
* T8 – `spends_one_script_utxo_with_nft` enforces single NFT script input usage.
* T9 – `spends_one_account_utxo_for_aggregation` validates aggregation account input.
* T10 – `returns_empty_account_outputs` confirms new reward accounts are zeroed.
* T11 – `returns_empty_aggstate_outputs` confirms new AggState outputs are empty.
* T12 – `find_out_datum_and_value` fetches output datum/value by NFT.
* T13 – `find_out_datum_and_value_with_allowing_asset` variant allowing extra asset.
* T14 – `find_referenced_datum` loads datum from reference inputs.
* T15 – `find_in_datum` retrieves inline datum from an input.
* T16 – `count_dismissed_reward_accounts` counts reward inputs dismissed.
* T17 – `check_reward_accounts_in_to_out_mapping` matches reward inputs to outputs.
* T18 – `get_length_and_check_strict_order` ensures integer list ascending order.
* T19 – `does_not_produce_own_nft_outputs` forbids minting extra protocol NFTs.
* T20 – `is_aggstate_expired` checks aggregation window expiry.
* T21 – `convert_reward_prices` converts fees using reference prices.
* T22 – `conserves_utxo_value` enforces exact input/output value conservation.
* T23 – `check_utxo_size_safety_buffer` keeps reward accounts above min ADA.
* T24 – `check_reward_distribution` validates reward distribution maps.
* T25 – `validate_message_and_count_nodes` checks median message ordering.
* T26 – `check_settings_sanity` keeps invariant settings untouched.
* T27 – `validate_settings_form` asserts settings format and token references.
* T28 – `check_pause_does_not_change_settings` ensures pause toggles only the flag.
* T29 – `find_node_by_signature` resolves the signing node.
* T30 – `check_node_received_reward` validates node withdrawals.
* T31 – `check_platform_received_reward` validates platform fee withdrawals.
* T32 – `check_nodes_update` validates node list additions/removals.
* T33 – `validate_dismissing_period` checks reward dismissal timeout.
* T34 – interquartile range collapsed to zero (IQRFence degeneration).


## License

This repository is licensed under the **GNU Affero General Public License v3.0 (AGPL-3.0)**.

We chose AGPL for the on-chain protocol components to ensure that improvements and modifications to the core protocol remain transparent and benefit the entire ecosystem, including node operators, developers, and token holders.

Off-chain tooling, SDKs, and supporting services may be licensed under different terms. Please refer to individual repository LICENSE files for details.

See [LICENSE](LICENSE) for the full license text.

## Official Deployments

Charli3 maintains and supports only official deployments that use the $C3 token and unmodified protocol economics.
