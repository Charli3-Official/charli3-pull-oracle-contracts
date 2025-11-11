use aiken/builtin
use aiken/collection/dict
use aiken/collection/list
use aiken/collection/pairs
use aiken/crypto.{ScriptHash}
use aiken/interval
use aiken/primitive/bytearray
use cardano/address
use cardano/assets.{AssetName, PolicyId} as assets
use cardano/transaction.{Input, Output, OutputReference, Transaction}
use cardano/transaction as tx
use config
use core/checks.{
  find_out_datum_and_value, returns_empty_account_outputs,
  returns_empty_aggstate_outputs, validate_settings_form,
}
use core/datum.{
  AggState, FeeConfig, GenericData, NftsConfiguration, OracleConfiguration,
  OracleSettings, OracleSettingsDatum, RewardAccount, RewardAccountDatum,
  RewardPrices, create_price_data,
}
use core/redeemer.{
  AddNodes, DelNodes, ManageSettings, MintToken, OdvAggregate, OdvAggregateMsg,
  UpdateSettings,
}
use ext/aiken/math/rational.{coin_precision}
use ext/cardano/value.{Asset}
use oracle
use services/nft_based_auth.{auth_by_nft}

const platform_policy_id: assets.PolicyId =
  #"000102030405060708090a0b0c0d0e0f101112131415161718191a1b"

const oracle_policy_id: assets.PolicyId =
  #"1c1d1e1f202122232425262728292a2b2c2d2e2f30313233343536373839"

const platform_script_hash: ScriptHash =
  #"404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c"

const oracle_script_hash: ScriptHash =
  #"5d5e5f606162636465666768696a6b6c6d6e6f70717273747576777879"

const platform_nft_name = #"504c4154464f524d"

const pause_period: Int = 86_400_000

const agg_liveness: Int = 3_600_000

const platform_uncertainty: Int = 600_000

const aggregation_uncertainty: Int = 120_000

const utxo_buffer: Int = 5_000_000

const node_fee: Int = 1_000_000

const platform_fee: Int = 500_000

const mock_conf =
  OracleConfiguration {
    platform_auth_nft: platform_policy_id,
    pause_period_length: pause_period,
    reward_dismissing_period_length: pause_period,
    fee_token: None,
  }

const mock_fee_token_policy_id: PolicyId = "C3 policy id"

const mock_fee_token_name: AssetName = "C3"

const mock_conf_with_token =
  OracleConfiguration {
    platform_auth_nft: platform_policy_id,
    pause_period_length: pause_period,
    reward_dismissing_period_length: pause_period,
    fee_token: Some(
      Asset { policy_id: mock_fee_token_policy_id, name: mock_fee_token_name },
    ),
  }

const mock_rate_nft =
  Asset { policy_id: "C3/USD policy id", name: config.aggstate_token_name }

// node VerificationKeyHash = Hash<Blake2b_224, VerificationKey>
// blake2b-224 hash digest is 28 bytes long
const mock_nodes =
  [
    "node01               FeedVkh", "node02               FeedVkh",
    "node03               FeedVkh", "node04               FeedVkh",
    "node05               FeedVkh", "node06               FeedVkh",
    "node07               FeedVkh", "node08               FeedVkh",
    "node09               FeedVkh", "node10               FeedVkh",
    "node11               FeedVkh", "node12               FeedVkh",
    "node13               FeedVkh", "node14               FeedVkh",
    "node15               FeedVkh", "node16               FeedVkh",
    "node17               FeedVkh", "node18               FeedVkh",
    "node19               FeedVkh", "node20               FeedVkh",
    "node21               FeedVkh",
  ]

const mock_settings =
  OracleSettingsDatum {
    nodes: mock_nodes,
    required_node_signatures_count: 16,
    fee_info: FeeConfig {
      rate_nft: None,
      reward_prices: RewardPrices { node_fee, platform_fee },
    },
    aggregation_liveness_period: agg_liveness,
    time_uncertainty_aggregation: aggregation_uncertainty,
    time_uncertainty_platform: platform_uncertainty,
    iqr_fence_multiplier: 150,
    median_divergency_factor: 10,
    utxo_size_safety_buffer: utxo_buffer,
    pause_period_started_at: None,
  }

const mock_nfts =
  NftsConfiguration {
    utxo_ref: OutputReference {
      transaction_id: #"f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff00112233445566778899aabbccddeeff",
      output_index: 0,
    },
    oracle_conf: mock_conf,
    oracle_script_hash,
  }

const platform_nft_output =
  Output {
    address: address.from_script(platform_script_hash),
    value: assets.from_asset(platform_policy_id, platform_nft_name, 1),
    datum: tx.NoDatum,
    reference_script: None,
  }

const platform_nft_input =
  tx.Input {
    output_reference: OutputReference {
      transaction_id: "some platform tx",
      output_index: 0,
    },
    output: platform_nft_output,
  }

const reward_account_output =
  Output {
    address: address.from_script(oracle_script_hash),
    value: assets.merge(
      assets.from_asset(oracle_policy_id, config.reward_account_token_name, 1),
      assets.from_lovelace(utxo_buffer),
    ),
    datum: tx.InlineDatum(
      RewardAccount(
        RewardAccountDatum { nodes_to_rewards: [], last_update_time: 0 },
      ),
    ),
    reference_script: None,
  }

const aggstate_output =
  Output {
    address: address.from_script(oracle_script_hash),
    value: assets.from_asset(oracle_policy_id, config.aggstate_token_name, 1),
    datum: tx.InlineDatum(AggState(GenericData { price_map: [] })),
    reference_script: None,
  }

const mock_core_settings_token_value =
  assets.from_asset(oracle_policy_id, config.core_settings_token_name, 1)

const core_settings_output =
  Output {
    address: address.from_script(oracle_script_hash),
    value: mock_core_settings_token_value,
    datum: tx.InlineDatum(OracleSettings(mock_settings)),
    reference_script: None,
  }

const minted_value =
  assets.zero
    |> assets.add(oracle_policy_id, config.core_settings_token_name, 1)
    |> assets.add(oracle_policy_id, config.reward_account_token_name, 1)
    |> assets.add(oracle_policy_id, config.aggstate_token_name, 1)

const mock_median: Int = 449999

const mock_node_feeds_count: Int = 21

const mock_node_fee: Int = 10_000_000

const mock_platform_fee: Int = 2_000_000

const mock_minimum_fee_amount: Int =
  mock_node_feeds_count * mock_node_fee + mock_platform_fee

const empty_oracle_feed = AggState(GenericData { price_map: [] })

const mock_aggstate_token_value =
  assets.from_asset(oracle_policy_id, config.aggstate_token_name, 1)

const mock_empty_aggstate_output =
  Output {
    address: address.from_script(oracle_script_hash),
    value: mock_aggstate_token_value,
    datum: tx.InlineDatum(empty_oracle_feed),
    reference_script: None,
  }

const mock_empty_reward_account_datum =
  RewardAccountDatum {
    nodes_to_rewards: list.map(mock_nodes, fn(node) { Pair(node, 0) }),
    last_update_time: 0,
  }

const mock_reward_account_token_value =
  assets.from_asset(oracle_policy_id, config.reward_account_token_name, 1)

const mock_empty_reward_account_output =
  Output {
    address: address.from_script(oracle_script_hash),
    value: mock_reward_account_token_value,
    datum: tx.InlineDatum(RewardAccount(mock_empty_reward_account_datum)),
    reference_script: None,
  }

const mock_precise_tx_validity_interval =
  interval.between(1732195907000, 1732195907000 + aggregation_uncertainty)

const mock_current_time =
  ( 1732195907000 + 1732195907000 + aggregation_uncertainty ) / 2

const mock_core_settings_input =
  tx.Input {
    output_reference: OutputReference {
      transaction_id: "core settings before odv aggregation tx",
      output_index: 0,
    },
    output: tx.Output {
      address: address.from_script(oracle_script_hash),
      value: mock_core_settings_token_value,
      datum: tx.InlineDatum(
        OracleSettings(
          OracleSettingsDatum {
            ..mock_settings,
            fee_info: FeeConfig {
              rate_nft: None,
              reward_prices: RewardPrices {
                node_fee: mock_node_fee,
                platform_fee: mock_platform_fee,
              },
            },
          },
        ),
      ),
      reference_script: None,
    },
  }

const mock_core_settings_input_using_ada_fee =
  tx.Input {
    output_reference: OutputReference {
      transaction_id: "some tx",
      output_index: 11,
    },
    output: tx.Output {
      address: address.from_script(oracle_script_hash),
      value: mock_core_settings_token_value,
      datum: tx.InlineDatum(OracleSettings(mock_settings)),
      reference_script: None,
    },
  }

const thirty_minutes: Int = 1_800_000

test successful_oracle_start() {
  let minted_assets = minted_value |> assets.tokens(oracle_policy_id)

  expect Some(1) = dict.get(minted_assets, config.core_settings_token_name)
  expect Some(1) = dict.get(minted_assets, config.reward_account_token_name)
  expect Some(1) = dict.get(minted_assets, config.aggstate_token_name)

  expect validate_settings_form(mock_conf, mock_settings)

  let reward_account_nft =
    Asset {
      policy_id: oracle_policy_id,
      name: config.reward_account_token_name,
    }
  let aggstate_nft =
    Asset { policy_id: oracle_policy_id, name: config.aggstate_token_name }
  let core_nft =
    Asset { policy_id: oracle_policy_id, name: config.core_settings_token_name }

  let oracle_outputs =
    [
      platform_nft_output, core_settings_output, reward_account_output,
      aggstate_output,
    ]

  expect
    returns_empty_account_outputs(
      oracle_script_hash,
      reward_account_nft,
      1,
      oracle_outputs,
      utxo_buffer,
    )

  expect
    returns_empty_aggstate_outputs(
      oracle_script_hash,
      aggstate_nft,
      1,
      oracle_outputs,
    )

  expect [(OracleSettings(_), _)] =
    find_out_datum_and_value(oracle_outputs, oracle_script_hash, core_nft)

  let platform_input =
    Input { output_reference: mock_nfts.utxo_ref, output: platform_nft_output }

  expect
    auth_by_nft(mock_conf.platform_auth_nft, [platform_input], oracle_outputs)

  let start_tx =
    Transaction {
      ..tx.placeholder,
      inputs: [platform_input],
      outputs: oracle_outputs,
      mint: minted_value,
    }

  expect
    oracle.oracle_nfts.mint(mock_nfts, MintToken, oracle_policy_id, start_tx)
}

test successful_update_settings() {
  let core_settings_ref =
    OutputReference {
      transaction_id: "core settings before update settings tx",
      output_index: 0,
    }
  let core_settings_input =
    tx.Input {
      output_reference: core_settings_ref,
      output: core_settings_output,
    }
  let core_settings_after =
    OracleSettingsDatum {
      ..mock_settings,
      required_node_signatures_count: 17,
      aggregation_liveness_period: 3_000_000,
      iqr_fence_multiplier: 170,
      fee_info: FeeConfig {
        rate_nft: Some(mock_rate_nft),
        reward_prices: RewardPrices {
          node_fee: node_fee / 10,
          platform_fee: platform_fee / 10,
        },
      },
    }
  let core_settings_output =
    tx.Output {
      address: address.from_script(oracle_script_hash),
      value: mock_core_settings_token_value,
      datum: tx.InlineDatum(OracleSettings(core_settings_after)),
      reference_script: None,
    }

  let update_settings_redeemer: Data = ManageSettings(UpdateSettings)
  let update_settings_tx =
    Transaction {
      ..tx.placeholder,
      inputs: [core_settings_input, platform_nft_input],
      redeemers: [Pair(tx.Spend(core_settings_ref), update_settings_redeemer)],
      outputs: [core_settings_output, platform_nft_output],
    }
  oracle.oracle_manager.spend(
    mock_conf_with_token,
    Some(OracleSettings(mock_settings)),
    ManageSettings(UpdateSettings),
    core_settings_ref,
    update_settings_tx,
  )
}

test successful_add_nodes() {
  let core_settings_ref =
    OutputReference {
      transaction_id: "core settings before add nodes tx",
      output_index: 0,
    }
  let core_settings_input =
    tx.Input {
      output_reference: core_settings_ref,
      output: tx.Output {
        address: address.from_script(oracle_script_hash),
        value: mock_core_settings_token_value,
        datum: tx.InlineDatum(OracleSettings(mock_settings)),
        reference_script: None,
      },
    }
  let core_settings_after =
    OracleSettingsDatum {
      ..mock_settings,
      nodes: [
        "node00               FeedVkh",
        ..list.concat(
          mock_nodes,
          ["node22               FeedVkh", "node23               FeedVkh"],
        )
      ],
      required_node_signatures_count: 19,
    }
  let core_settings_output =
    tx.Output {
      address: address.from_script(oracle_script_hash),
      value: mock_core_settings_token_value,
      datum: tx.InlineDatum(OracleSettings(core_settings_after)),
      reference_script: None,
    }

  let add_nodes_redeemer: Data = ManageSettings(AddNodes)
  let add_nodes_tx =
    Transaction {
      ..tx.placeholder,
      inputs: [core_settings_input, platform_nft_input],
      redeemers: [Pair(tx.Spend(core_settings_ref), add_nodes_redeemer)],
      outputs: [core_settings_output, platform_nft_output],
    }

  oracle.oracle_manager.spend(
    mock_conf_with_token,
    Some(OracleSettings(mock_settings)),
    ManageSettings(AddNodes),
    core_settings_ref,
    add_nodes_tx,
  )
}

test successful_del_nodes() {
  let core_settings_ref =
    OutputReference {
      transaction_id: "core settings before del nodes tx",
      output_index: 0,
    }
  let core_settings_input =
    tx.Input {
      output_reference: core_settings_ref,
      output: tx.Output {
        address: address.from_script(oracle_script_hash),
        value: mock_core_settings_token_value,
        datum: tx.InlineDatum(OracleSettings(mock_settings)),
        reference_script: None,
      },
    }
  let core_settings_after =
    OracleSettingsDatum {
      ..mock_settings,
      nodes: list.delete(mock_nodes, "node16               FeedVkh"),
      required_node_signatures_count: 15,
    }
  let core_settings_output =
    tx.Output {
      address: address.from_script(oracle_script_hash),
      value: mock_core_settings_token_value,
      datum: tx.InlineDatum(OracleSettings(core_settings_after)),
      reference_script: None,
    }

  let del_nodes_redeemer: Data = ManageSettings(DelNodes)
  let del_nodes_tx =
    Transaction {
      ..tx.placeholder,
      inputs: [core_settings_input, platform_nft_input],
      redeemers: [Pair(tx.Spend(core_settings_ref), del_nodes_redeemer)],
      outputs: [core_settings_output, platform_nft_output],
    }

  oracle.oracle_manager.spend(
    mock_conf_with_token,
    Some(OracleSettings(mock_settings)),
    ManageSettings(DelNodes),
    core_settings_ref,
    del_nodes_tx,
  )
}

test successful_odv_aggregation() {
  let aggstate_ref =
    OutputReference {
      transaction_id: #"61676773746174655f746f6b656e",
      output_index: 0,
    }
  let aggstate_before = empty_oracle_feed
  let aggstate_after =
    AggState(
      create_price_data(
        mock_median,
        mock_current_time,
        mock_current_time + agg_liveness,
      ),
    )
  let aggstate_input =
    Input { output_reference: aggstate_ref, output: mock_empty_aggstate_output }
  let aggstate_output =
    Output {
      address: address.from_script(oracle_script_hash),
      value: mock_aggstate_token_value,
      datum: tx.InlineDatum(aggstate_after),
      reference_script: None,
    }

  let reward_account_ref =
    OutputReference {
      transaction_id: #"7265776172645f746f6b656e",
      output_index: 0,
    }

  let mock_node_feeds_sorted =
    list.map(mock_nodes, fn(node) { Pair(node, mock_median) })

  let expected_nodes_to_rewards =
    list.map(mock_nodes, fn(node) { Pair(node, mock_node_fee) })

  let sorted_expected_nodes_to_rewards =
    expected_nodes_to_rewards
      |> list.sort(
          fn(p1: Pair<ByteArray, Int>, p2: Pair<ByteArray, Int>) -> Ordering {
            bytearray.compare(builtin.fst_pair(p1), builtin.fst_pair(p2))
          },
        )
  let reward_account_after =
    RewardAccount(
      RewardAccountDatum {
        nodes_to_rewards: sorted_expected_nodes_to_rewards,
        last_update_time: mock_current_time,
      },
    )

  let reward_account_before = RewardAccount(mock_empty_reward_account_datum)

  let reward_account_input =
    Input {
      output_reference: reward_account_ref,
      output: mock_empty_reward_account_output,
    }
  let reward_account_output =
    Output {
      address: address.from_script(oracle_script_hash),
      value: assets.merge(
        mock_reward_account_token_value,
        assets.merge(
          assets.from_lovelace(utxo_buffer),
          assets.from_asset(
            mock_fee_token_policy_id,
            mock_fee_token_name,
            mock_minimum_fee_amount,
          ),
        ),
      ),
      datum: tx.InlineDatum(reward_account_after),
      reference_script: None,
    }

  let odv_aggregate_redeemer: Data = OdvAggregate(mock_node_feeds_sorted)
  let odv_aggregate_msg_redeemer: Data = OdvAggregateMsg
  let signatories_from_feeds =
    mock_node_feeds_sorted
      |> pairs.keys
      |> list.sort(
          fn(a: ByteArray, b: ByteArray) -> Ordering { bytearray.compare(a, b) },
        )

  let aggregation_tx =
    Transaction {
      ..tx.placeholder,
      reference_inputs: [mock_core_settings_input],
      inputs: [reward_account_input, aggstate_input],
      redeemers: [
        Pair(tx.Spend(reward_account_ref), odv_aggregate_redeemer),
        Pair(tx.Spend(aggstate_ref), odv_aggregate_msg_redeemer),
      ],
      outputs: [reward_account_output, aggstate_output],
      validity_range: mock_precise_tx_validity_interval,
      extra_signatories: signatories_from_feeds,
    }

  expect
    oracle.oracle_manager.spend(
      mock_conf_with_token,
      Some(reward_account_before),
      OdvAggregate(mock_node_feeds_sorted),
      reward_account_ref,
      aggregation_tx,
    ) && oracle.oracle_manager.spend(
      mock_conf_with_token,
      Some(aggstate_before),
      OdvAggregateMsg,
      aggstate_ref,
      aggregation_tx,
    )
}

test successful_odv_aggregation_with_ada_fees() {
  let aggstate_ref =
    OutputReference {
      transaction_id: #"61676773746174655f746f6b656e",
      output_index: 0,
    }
  let aggstate_before = empty_oracle_feed
  let aggstate_after =
    AggState(
      create_price_data(
        mock_median,
        mock_current_time,
        mock_current_time + agg_liveness,
      ),
    )
  let aggstate_input =
    Input { output_reference: aggstate_ref, output: mock_empty_aggstate_output }
  let aggstate_output =
    Output {
      address: address.from_script(oracle_script_hash),
      value: mock_aggstate_token_value,
      datum: tx.InlineDatum(aggstate_after),
      reference_script: None,
    }

  let reward_account_ref =
    OutputReference {
      transaction_id: #"7265776172645f746f6b656e",
      output_index: 0,
    }

  let mock_node_feeds_sorted =
    list.map(mock_nodes, fn(node) { Pair(node, mock_median) })

  let expected_nodes_to_rewards =
    list.map(mock_nodes, fn(node) { Pair(node, node_fee) })

  let sorted_expected_nodes_to_rewards =
    expected_nodes_to_rewards
      |> list.sort(
          fn(p1: Pair<ByteArray, Int>, p2: Pair<ByteArray, Int>) -> Ordering {
            bytearray.compare(builtin.fst_pair(p1), builtin.fst_pair(p2))
          },
        )

  let reward_account_after =
    RewardAccount(
      RewardAccountDatum {
        nodes_to_rewards: sorted_expected_nodes_to_rewards,
        last_update_time: mock_current_time,
      },
    )

  let reward_account_before = RewardAccount(mock_empty_reward_account_datum)

  let reward_account_input =
    Input {
      output_reference: reward_account_ref,
      output: mock_empty_reward_account_output,
    }

  // Calculate correct minimum fee for ADA
  let minimum_fee_amount_for_ada =
    mock_node_feeds_count * node_fee + platform_fee

  let reward_account_output =
    Output {
      address: address.from_script(oracle_script_hash),
      value: assets.merge(
        mock_reward_account_token_value,
        assets.merge(
          assets.from_lovelace(utxo_buffer),
          assets.from_lovelace(minimum_fee_amount_for_ada),
        ),
      ),
      datum: tx.InlineDatum(reward_account_after),
      reference_script: None,
    }

  let odv_aggregate_redeemer: Data = OdvAggregate(mock_node_feeds_sorted)
  let odv_aggregate_msg_redeemer: Data = OdvAggregateMsg
  let signatories_from_feeds =
    mock_node_feeds_sorted
      |> pairs.keys
      |> list.sort(
          fn(a: ByteArray, b: ByteArray) -> Ordering { bytearray.compare(a, b) },
        )
  let aggregation_tx =
    Transaction {
      ..tx.placeholder,
      reference_inputs: [mock_core_settings_input_using_ada_fee],
      inputs: [reward_account_input, aggstate_input],
      redeemers: [
        Pair(tx.Spend(reward_account_ref), odv_aggregate_redeemer),
        Pair(tx.Spend(aggstate_ref), odv_aggregate_msg_redeemer),
      ],
      outputs: [reward_account_output, aggstate_output],
      validity_range: mock_precise_tx_validity_interval,
      extra_signatories: signatories_from_feeds,
    }

  expect
    oracle.oracle_manager.spend(
      mock_conf,
      Some(reward_account_before),
      OdvAggregate(mock_node_feeds_sorted),
      reward_account_ref,
      aggregation_tx,
    ) && oracle.oracle_manager.spend(
      mock_conf,
      Some(aggstate_before),
      OdvAggregateMsg,
      aggstate_ref,
      aggregation_tx,
    )
}

test successful_odv_aggregation_with_dynamic_oracle_fees_calculation() {
  let core_settings_input =
    tx.Input {
      output_reference: OutputReference {
        transaction_id: "some tx",
        output_index: 1,
      },
      output: tx.Output {
        address: address.from_script(oracle_script_hash),
        value: mock_core_settings_token_value,
        datum: tx.InlineDatum(
          OracleSettings(
            OracleSettingsDatum {
              ..mock_settings,
              fee_info: FeeConfig {
                rate_nft: Some(mock_rate_nft),
                reward_prices: RewardPrices { node_fee, platform_fee },
              },
            },
          ),
        ),
        reference_script: None,
      },
    }

  let c3_rate: Int = 130_000

  let convert_to_rate =
    fn(amount: Int) -> Int {
      ( amount * c3_rate + coin_precision - 1 ) / coin_precision
    }

  let c3_rate_input =
    tx.Input {
      output_reference: OutputReference {
        transaction_id: "some tx",
        output_index: 2,
      },
      output: tx.Output {
        address: address.from_script(oracle_script_hash),
        value: assets.from_asset(
          mock_rate_nft.policy_id,
          config.aggstate_token_name,
          1,
        ),
        datum: tx.InlineDatum(
          AggState(
            create_price_data(
              c3_rate,
              mock_current_time - thirty_minutes / 2,
              mock_current_time - thirty_minutes / 2 + agg_liveness,
            ),
          ),
        ),
        reference_script: None,
      },
    }

  let aggstate_ref =
    OutputReference {
      transaction_id: #"61676773746174655f746f6b656e",
      output_index: 0,
    }
  let aggstate_before = empty_oracle_feed
  let aggstate_after =
    AggState(
      create_price_data(
        mock_median,
        mock_current_time,
        mock_current_time + agg_liveness,
      ),
    )
  let aggstate_input =
    Input { output_reference: aggstate_ref, output: mock_empty_aggstate_output }
  let aggstate_output =
    Output {
      address: address.from_script(oracle_script_hash),
      value: mock_aggstate_token_value,
      datum: tx.InlineDatum(aggstate_after),
      reference_script: None,
    }

  let reward_account_ref =
    OutputReference {
      transaction_id: #"7265776172645f746f6b656e",
      output_index: 0,
    }
  let reward_account_before = RewardAccount(mock_empty_reward_account_datum)

  let mock_node_feeds_sorted =
    list.map(mock_nodes, fn(node) { Pair(node, mock_median) })

  let expected_nodes_to_rewards =
    list.map(mock_nodes, fn(node) { Pair(node, convert_to_rate(node_fee)) })
  let sorted_expected_nodes_to_rewards =
    expected_nodes_to_rewards
      |> list.sort(
          fn(p1: Pair<ByteArray, Int>, p2: Pair<ByteArray, Int>) -> Ordering {
            bytearray.compare(builtin.fst_pair(p1), builtin.fst_pair(p2))
          },
        )

  let reward_account_after =
    RewardAccount(
      RewardAccountDatum {
        nodes_to_rewards: sorted_expected_nodes_to_rewards,
        last_update_time: mock_current_time,
      },
    )

  let reward_account_input =
    Input {
      output_reference: reward_account_ref,
      output: mock_empty_reward_account_output,
    }

  let minimum_fee_amount_for_dynamic =
    convert_to_rate(mock_node_feeds_count * node_fee + platform_fee)

  let reward_account_output =
    Output {
      address: address.from_script(oracle_script_hash),
      value: assets.merge(
        mock_reward_account_token_value,
        assets.merge(
          assets.from_lovelace(utxo_buffer),
          assets.from_asset(
            mock_fee_token_policy_id,
            mock_fee_token_name,
            minimum_fee_amount_for_dynamic,
          ),
        ),
      ),
      datum: tx.InlineDatum(reward_account_after),
      reference_script: None,
    }

  let odv_aggregate_redeemer: Data = OdvAggregate(mock_node_feeds_sorted)
  let odv_aggregate_msg_redeemer: Data = OdvAggregateMsg
  let signatories_from_feeds =
    mock_node_feeds_sorted
      |> pairs.keys
      |> list.sort(
          fn(a: ByteArray, b: ByteArray) -> Ordering { bytearray.compare(a, b) },
        )
  let aggregation_tx =
    Transaction {
      ..tx.placeholder,
      reference_inputs: [core_settings_input, c3_rate_input],
      inputs: [reward_account_input, aggstate_input],
      redeemers: [
        Pair(tx.Spend(reward_account_ref), odv_aggregate_redeemer),
        Pair(tx.Spend(aggstate_ref), odv_aggregate_msg_redeemer),
      ],
      outputs: [reward_account_output, aggstate_output],
      validity_range: mock_precise_tx_validity_interval,
      extra_signatories: signatories_from_feeds,
    }

  expect
    oracle.oracle_manager.spend(
      mock_conf_with_token,
      Some(aggstate_before),
      OdvAggregateMsg,
      aggstate_ref,
      aggregation_tx,
    ) && oracle.oracle_manager.spend(
      mock_conf_with_token,
      Some(reward_account_before),
      OdvAggregate(mock_node_feeds_sorted),
      reward_account_ref,
      aggregation_tx,
    )
}
