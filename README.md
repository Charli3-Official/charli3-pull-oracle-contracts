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

Simply install latest version of aiken (change version tag) `nix profile install github:aiken-lang/aiken/v1.1.3#aiken`.

## Validators trace messages and codes

Validators trace messages and codes with their mapping are described here.

To reduce script size we can remove traces altogether, but then it's hard to know where error is coming from, especially when doing debugging in testnets.
Other option is to use short trace and error codes instead of messages, this document describes them.

### Errors

Direct failures that cause code to stop evaluation and return the error.

* E1 - validator supports only mint purpose;
* E2 - validator supports only spend purpose;
* E3 - Oracle Manager Script state transition not allowed;
* E4 - median: less than four nodes;
* E5 - median: empty list;
* E6 - consensus_by_iqr: less than four nodes;
* E7 - check node feeds ascending order;
* E8 - check node ids (feed vkhs) ascending order.

### Traces

Trace message is added to the list (evaluation context) when evaluation comes to a particular code branch, it will be added on every evaluation failure as well as success.

* T1 - scale up;
* T2 - scale down;
* T3 - find_own_protocol_policy_id;
* T4 - get_current_time;
* T5 - auth_by_nft;
* T6 - check_nodes_multisig;
* T7 - spends_protocol_nft_inputs;
* T8 - spends_one_script_utxo_with_nft;
* T9 - returns_empty_reward_outputs;
* T10 - returns_empty_aggstate_outputs;
* T11 - find_out_datum_and_value;
* T12 - find_out_datum_and_value_with_allowing_asset;
* T13 - find_referenced_datum;
* T14 - find_in_datum;
* T15 - find_in_aggregations;
* T16 - does_not_produce_own_nft_outputs;
* T17 - is_aggstate_expired;
* T18 - convert_reward_prices;
* T19 - oracle_fees_were_transferred;
* T20 - check_reward_distribution;
* T21 - validate_message_form;
* T22 - check_settings_sanity;
* T23 - check_fee_settings_sanity;
* T24 - check_closing_does_not_change_settings;
* T25 - find_node_index_by_signature;
* T26 - check_node_received_reward;
* T27 - check_platform_received_reward;
* T28 - check_added_nodes;
* T29 - check_deleted_nodes.
