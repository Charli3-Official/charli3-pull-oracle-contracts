use aiken/builtin
use aiken/collection/list
use aiken/collection/pairs
use aiken/crypto.{ScriptHash}
use aiken/interval
use aiken/math/rational
use aiken/primitive/int
use cardano/address
use cardano/assets.{PolicyId}
use cardano/transaction.{OutputReference, Transaction}
use cardano/transaction as tx
use config
use ext/aiken/math/rational.{coin_precision} as ext
use ext/aiken/time.{PosixTimeDiff}
use ext/cardano/value.{Asset}
use oracle
use oracle/datum.{
  AggState, AggStateDatum, AggregateMessage, Aggregation, FeeConfig, FeedVkh,
  NoRewards, NodeFeed, OracleConfiguration, OracleSettings, OracleSettingsDatum,
  RewardAccount, RewardAccountDatum, RewardConsensusPending, RewardPrices,
  RewardTransport,
}
use oracle/redeemer.{
  AddNodes, BurnToken, CalculateRewards, CloseOracle, DelNodes, DismissRewards,
  MintToken, NodeCollect, OdvAggregate, PlatformCollect, RemoveOracle,
  ReopenOracle, ScaleDown, ScaleToken, SetFeeConfig, UpdateSettings,
}

const twenty_four_hours: PosixTimeDiff = 24 * 60 * 60 * 1000

const one_hour: PosixTimeDiff = 60 * 60 * 1000

const thirty_minutes: PosixTimeDiff = 30 * 60 * 1000

const three_minutes: PosixTimeDiff = 3 * 60 * 1000

const mock_manager_script_hash: ScriptHash = "oracle manager script hash"

const mock_oracle_nft_script_hash: ScriptHash = "oracle nft script hash"

const mock_auth_script_hash: ScriptHash = "platform auth script hash"

const mock_platform_auth_policy_id: PolicyId = "platform auth NFT policy id"

const mock_fee_token_policy_id = "C3 policy id"

const mock_fee_token_name = "C3"

const mock_oracle_conf =
  OracleConfiguration {
    platform_auth_nft: mock_platform_auth_policy_id,
    closing_period_length: twenty_four_hours,
    reward_dismissing_period_length: twenty_four_hours,
    fee_token: Some(
      Asset { policy_id: mock_fee_token_policy_id, name: mock_fee_token_name },
    ),
  }

const mock_oracle_conf_using_ada_fee =
  OracleConfiguration {
    platform_auth_nft: mock_platform_auth_policy_id,
    closing_period_length: twenty_four_hours,
    reward_dismissing_period_length: twenty_four_hours,
    fee_token: None,
  }

const mock_nodes =
  [
    Pair("node01 FeedVkh", "node01 PaymentVkh"),
    Pair("node02 FeedVkh", "node02 PaymentVkh"),
    Pair("node03 FeedVkh", "node03 PaymentVkh"),
    Pair("node04 FeedVkh", "node04 PaymentVkh"),
    Pair("node05 FeedVkh", "node05 PaymentVkh"),
    Pair("node06 FeedVkh", "node06 PaymentVkh"),
    Pair("node07 FeedVkh", "node07 PaymentVkh"),
    Pair("node08 FeedVkh", "node08 PaymentVkh"),
    Pair("node09 FeedVkh", "node09 PaymentVkh"),
    Pair("node10 FeedVkh", "node10 PaymentVkh"),
    Pair("node11 FeedVkh", "node11 PaymentVkh"),
    Pair("node12 FeedVkh", "node12 PaymentVkh"),
    Pair("node13 FeedVkh", "node13 PaymentVkh"),
    Pair("node14 FeedVkh", "node14 PaymentVkh"),
    Pair("node15 FeedVkh", "node15 PaymentVkh"),
    Pair("node16 FeedVkh", "node16 PaymentVkh"),
    Pair("node17 FeedVkh", "node17 PaymentVkh"),
  ]

const mock_node_feeds: Pairs<FeedVkh, NodeFeed> =
  [
    449998, 449999, 449982, 449996, 450027, 449998, 450024, 449974, 450015,
    450026, 450000, 449991, 450014, 450009, 450113, 449989, 449994,
  ]
    |> list.map2(
        mock_nodes,
        _,
        fn(node, feed) { Pair(builtin.fst_pair(node), feed) },
      )
    |> list.sort(
        fn(p1, p2) { int.compare(builtin.snd_pair(p1), builtin.snd_pair(p2)) },
      )

const mock_median = 449999

const mock_node_feeds_count = 17

const mock_node_fee = 10_000_000

const mock_platform_fee = 2_000_000

const mock_nodes_rewards =
  [
    mock_node_fee, mock_node_fee, mock_node_fee, mock_node_fee, mock_node_fee,
    mock_node_fee, mock_node_fee, mock_node_fee, mock_node_fee, mock_node_fee,
    mock_node_fee, mock_node_fee, mock_node_fee, mock_node_fee, 0, mock_node_fee,
    mock_node_fee,
  ]

const mock_oracle_settings =
  OracleSettingsDatum {
    nodes: mock_nodes,
    required_node_signatures_count: mock_node_feeds_count,
    fee_info: FeeConfig {
      rate_nft: None,
      reward_prices: RewardPrices {
        node_fee: mock_node_fee,
        platform_fee: mock_platform_fee,
      },
    },
    aggregation_liveness_period: one_hour,
    time_absolute_uncertainty: three_minutes,
    iqr_fence_multiplier: 150,
    utxo_size_safety_buffer: 0,
    closing_period_started_at: None,
  }

const mock_utxo_size_safety_buffer = 5_500_000

const mock_oracle_settings_using_ada_fee =
  OracleSettingsDatum {
    nodes: mock_nodes,
    required_node_signatures_count: mock_node_feeds_count,
    fee_info: FeeConfig {
      rate_nft: None,
      reward_prices: RewardPrices {
        node_fee: mock_node_fee,
        platform_fee: mock_platform_fee,
      },
    },
    aggregation_liveness_period: one_hour,
    time_absolute_uncertainty: three_minutes,
    iqr_fence_multiplier: 150,
    utxo_size_safety_buffer: mock_utxo_size_safety_buffer,
    closing_period_started_at: None,
  }

const mock_rate_nft =
  Asset { policy_id: "C3/USD policy id", name: config.aggstate_token_name }

const mock_minimum_fee_amount =
  mock_node_feeds_count * mock_node_fee + mock_platform_fee

const mock_platform_nft_value =
  assets.from_asset(mock_platform_auth_policy_id, "Admin", 1)

const mock_platform_nft_output =
  tx.Output {
    address: address.from_script(mock_auth_script_hash),
    value: mock_platform_nft_value,
    datum: tx.NoDatum,
    reference_script: None,
  }

const mock_platform_nft_input =
  tx.Input {
    output_reference: OutputReference {
      transaction_id: "some platform tx",
      output_index: 0,
    },
    output: mock_platform_nft_output,
  }

const mock_core_settings_token_value =
  assets.from_asset(
    mock_oracle_nft_script_hash,
    config.core_settings_token_name,
    1,
  )

const mock_core_settings_output =
  tx.Output {
    address: address.from_script(mock_manager_script_hash),
    value: mock_core_settings_token_value,
    datum: tx.InlineDatum(OracleSettings(mock_oracle_settings)),
    reference_script: None,
  }

const mock_core_settings_output_using_ada_fee =
  tx.Output {
    address: address.from_script(mock_manager_script_hash),
    value: mock_core_settings_token_value,
    datum: tx.InlineDatum(OracleSettings(mock_oracle_settings_using_ada_fee)),
    reference_script: None,
  }

const mock_core_settings_input =
  tx.Input {
    output_reference: OutputReference {
      transaction_id: "some tx",
      output_index: 11,
    },
    output: mock_core_settings_output,
  }

const mock_core_settings_input_using_ada_fee =
  tx.Input {
    output_reference: OutputReference {
      transaction_id: "some tx",
      output_index: 11,
    },
    output: mock_core_settings_output_using_ada_fee,
  }

const mock_reward_account_token_value =
  assets.from_asset(
    mock_oracle_nft_script_hash,
    config.reward_account_token_name,
    1,
  )

const mock_reward_transport_token_value =
  assets.from_asset(
    mock_oracle_nft_script_hash,
    config.reward_transport_token_name,
    1,
  )

const mock_aggstate_token_value =
  assets.from_asset(mock_oracle_nft_script_hash, config.aggstate_token_name, 1)

const mock_empty_reward_transport_output =
  tx.Output {
    address: address.from_script(mock_manager_script_hash),
    value: mock_reward_transport_token_value,
    datum: tx.InlineDatum(RewardTransport(NoRewards)),
    reference_script: None,
  }

fn mock_empty_reward_transport_outputs(count: Int) {
  list.repeat(mock_empty_reward_transport_output, count)
}

const mock_empty_aggstate_output =
  tx.Output {
    address: address.from_script(mock_manager_script_hash),
    value: mock_aggstate_token_value,
    datum: tx.InlineDatum(AggState(None)),
    reference_script: None,
  }

fn mock_empty_aggstate_outputs(count: Int) {
  list.repeat(mock_empty_aggstate_output, count)
}

const mock_empty_reward_account_datum =
  RewardAccountDatum(list.repeat(0, mock_node_feeds_count))

const mock_empty_reward_account_output =
  tx.Output {
    address: address.from_script(mock_manager_script_hash),
    value: mock_reward_account_token_value,
    datum: tx.InlineDatum(RewardAccount(mock_empty_reward_account_datum)),
    reference_script: None,
  }

const mock_precise_tx_validity_interval =
  interval.between(1732195907000, 1732195907000 + three_minutes)

const mock_current_time = ( 1732195907000 + 1732195907000 + three_minutes ) / 2

const mock_starting_platform_utxo =
  OutputReference { transaction_id: "before start tx", output_index: 0 }

test successful_oracle_start() {
  let platform_input =
    tx.Input {
      output_reference: mock_starting_platform_utxo,
      output: mock_platform_nft_output,
    }
  let minted_tokens_value =
    assets.from_asset_list(
      [
        Pair(
          mock_oracle_nft_script_hash,
          [
            Pair(config.aggstate_token_name, 3),
            Pair(config.core_settings_token_name, 1),
            Pair(config.reward_account_token_name, 1),
            Pair(config.reward_transport_token_name, 3),
          ],
        ),
      ],
    )
  let reward_transport_outputs = mock_empty_reward_transport_outputs(3)
  let aggstate_outputs = mock_empty_aggstate_outputs(3)

  let start_tx =
    Transaction {
      ..tx.placeholder,
      inputs: [platform_input],
      outputs: [
        mock_platform_nft_output, mock_core_settings_output,
        mock_empty_reward_account_output,
      ]
        |> list.concat(reward_transport_outputs)
        |> list.concat(aggstate_outputs),
      mint: minted_tokens_value,
    }
  oracle.oracle_nfts.mint(
    mock_starting_platform_utxo,
    mock_oracle_conf,
    mock_manager_script_hash,
    MintToken,
    mock_oracle_nft_script_hash,
    start_tx,
  )
}

test successful_odv_aggregation() {
  let aggstate_ref =
    OutputReference {
      transaction_id: "aggstate before odv aggregation tx",
      output_index: 0,
    }
  let aggstate_before = AggState(None)
  let aggstate_after =
    AggState(
      Some(
        AggStateDatum {
          oracle_feed: mock_median,
          expiry_timestamp: mock_current_time + one_hour,
          created_at: mock_current_time,
        },
      ),
    )
  let aggstate_input =
    tx.Input {
      output_reference: aggstate_ref,
      output: mock_empty_aggstate_output,
    }
  let aggstate_output =
    tx.Output {
      address: address.from_script(mock_manager_script_hash),
      value: mock_aggstate_token_value,
      datum: tx.InlineDatum(aggstate_after),
      reference_script: None,
    }

  let reward_transport_ref =
    OutputReference {
      transaction_id: "reward transport before odv aggregation tx",
      output_index: 0,
    }
  let reward_transport_before = RewardTransport(NoRewards)
  let reward_transport_after =
    RewardTransport(
      RewardConsensusPending(
        Aggregation {
          oracle_feed: mock_median,
          message: AggregateMessage {
            node_feeds_sorted_by_feed: mock_node_feeds,
            node_feeds_count: mock_node_feeds_count,
            timestamp: mock_current_time,
          },
          node_reward_price: mock_node_fee,
          rewards_amount_paid: mock_minimum_fee_amount,
        },
      ),
    )
  let reward_transport_input =
    tx.Input {
      output_reference: reward_transport_ref,
      output: mock_empty_reward_transport_output,
    }
  let reward_transport_output =
    tx.Output {
      address: address.from_script(mock_manager_script_hash),
      value: assets.merge(
        mock_reward_transport_token_value,
        assets.from_asset(
          mock_fee_token_policy_id,
          mock_fee_token_name,
          mock_minimum_fee_amount,
        ),
      ),
      datum: tx.InlineDatum(reward_transport_after),
      reference_script: None,
    }

  let odv_aggregate_redeemer: Data = OdvAggregate
  let aggregation_tx =
    Transaction {
      ..tx.placeholder,
      reference_inputs: [mock_core_settings_input],
      inputs: [reward_transport_input, aggstate_input],
      redeemers: [
        Pair(tx.Spend(aggstate_ref), odv_aggregate_redeemer),
        Pair(tx.Spend(reward_transport_ref), odv_aggregate_redeemer),
      ],
      outputs: [reward_transport_output, aggstate_output],
      validity_range: mock_precise_tx_validity_interval,
      extra_signatories: pairs.keys(mock_nodes),
    }
  oracle.oracle_manager.spend(
    mock_oracle_conf,
    Some(aggstate_before),
    OdvAggregate,
    aggstate_ref,
    aggregation_tx,
  ) && oracle.oracle_manager.spend(
    mock_oracle_conf,
    Some(reward_transport_before),
    OdvAggregate,
    reward_transport_ref,
    aggregation_tx,
  )
}

test successful_odv_aggregation_with_ada_fees() {
  let aggstate_ref =
    OutputReference {
      transaction_id: "aggstate before odv aggregation tx",
      output_index: 0,
    }
  let aggstate_before = AggState(None)
  let aggstate_after =
    AggState(
      Some(
        AggStateDatum {
          oracle_feed: mock_median,
          expiry_timestamp: mock_current_time + one_hour,
          created_at: mock_current_time,
        },
      ),
    )
  let aggstate_input =
    tx.Input {
      output_reference: aggstate_ref,
      output: mock_empty_aggstate_output,
    }
  let aggstate_output =
    tx.Output {
      address: address.from_script(mock_manager_script_hash),
      value: mock_aggstate_token_value,
      datum: tx.InlineDatum(aggstate_after),
      reference_script: None,
    }

  let reward_transport_ref =
    OutputReference {
      transaction_id: "reward transport before odv aggregation tx",
      output_index: 0,
    }
  let reward_transport_before = RewardTransport(NoRewards)
  let reward_transport_after =
    RewardTransport(
      RewardConsensusPending(
        Aggregation {
          oracle_feed: mock_median,
          message: AggregateMessage {
            node_feeds_sorted_by_feed: mock_node_feeds,
            node_feeds_count: mock_node_feeds_count,
            timestamp: mock_current_time,
          },
          node_reward_price: mock_node_fee,
          rewards_amount_paid: mock_minimum_fee_amount,
        },
      ),
    )
  let reward_transport_input =
    tx.Input {
      output_reference: reward_transport_ref,
      output: mock_empty_reward_transport_output,
    }
  let reward_transport_output =
    tx.Output {
      address: address.from_script(mock_manager_script_hash),
      value: assets.merge(
        mock_reward_transport_token_value,
        assets.from_lovelace(mock_minimum_fee_amount),
      ),
      datum: tx.InlineDatum(reward_transport_after),
      reference_script: None,
    }

  let odv_aggregate_redeemer: Data = OdvAggregate
  let aggregation_tx =
    Transaction {
      ..tx.placeholder,
      reference_inputs: [mock_core_settings_input_using_ada_fee],
      inputs: [reward_transport_input, aggstate_input],
      redeemers: [
        Pair(tx.Spend(aggstate_ref), odv_aggregate_redeemer),
        Pair(tx.Spend(reward_transport_ref), odv_aggregate_redeemer),
      ],
      outputs: [reward_transport_output, aggstate_output],
      validity_range: mock_precise_tx_validity_interval,
      extra_signatories: pairs.keys(mock_nodes),
    }
  oracle.oracle_manager.spend(
    mock_oracle_conf_using_ada_fee,
    Some(aggstate_before),
    OdvAggregate,
    aggstate_ref,
    aggregation_tx,
  ) && oracle.oracle_manager.spend(
    mock_oracle_conf_using_ada_fee,
    Some(reward_transport_before),
    OdvAggregate,
    reward_transport_ref,
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
        address: address.from_script(mock_manager_script_hash),
        value: mock_core_settings_token_value,
        datum: tx.InlineDatum(
          OracleSettings(
            OracleSettingsDatum {
              ..mock_oracle_settings,
              fee_info: FeeConfig {
                rate_nft: Some(mock_rate_nft),
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
  let c3_rate = 130_000
  let convert_to_rate =
    fn(amount: Int) -> Int {
      expect Some(rate) = rational.new(c3_rate, coin_precision)
      rational.from_int(amount) |> rational.mul(rate) |> rational.ceil
    }
  let c3_rate_input =
    tx.Input {
      output_reference: OutputReference {
        transaction_id: "some tx",
        output_index: 2,
      },
      output: tx.Output {
        address: address.from_script(mock_manager_script_hash),
        value: assets.from_asset(
          mock_rate_nft.policy_id,
          config.aggstate_token_name,
          1,
        ),
        datum: tx.InlineDatum(
          AggState(
            Some(
              AggStateDatum {
                oracle_feed: c3_rate,
                expiry_timestamp: mock_current_time - thirty_minutes / 2 + one_hour,
                created_at: mock_current_time - thirty_minutes / 2,
              },
            ),
          ),
        ),
        reference_script: None,
      },
    }

  let aggstate_ref =
    OutputReference {
      transaction_id: "aggstate before odv aggregation tx",
      output_index: 0,
    }
  let aggstate_before = AggState(None)
  let aggstate_after =
    AggState(
      Some(
        AggStateDatum {
          oracle_feed: mock_median,
          expiry_timestamp: mock_current_time + one_hour,
          created_at: mock_current_time,
        },
      ),
    )
  let aggstate_input =
    tx.Input {
      output_reference: aggstate_ref,
      output: mock_empty_aggstate_output,
    }
  let aggstate_output =
    tx.Output {
      address: address.from_script(mock_manager_script_hash),
      value: mock_aggstate_token_value,
      datum: tx.InlineDatum(aggstate_after),
      reference_script: None,
    }

  let reward_transport_ref =
    OutputReference {
      transaction_id: "reward transport before odv aggregation tx",
      output_index: 0,
    }
  let reward_transport_before = RewardTransport(NoRewards)
  let reward_transport_after =
    RewardTransport(
      RewardConsensusPending(
        Aggregation {
          oracle_feed: mock_median,
          message: AggregateMessage {
            node_feeds_sorted_by_feed: mock_node_feeds,
            node_feeds_count: mock_node_feeds_count,
            timestamp: mock_current_time,
          },
          node_reward_price: convert_to_rate(mock_node_fee),
          rewards_amount_paid: convert_to_rate(mock_minimum_fee_amount),
        },
      ),
    )
  let reward_transport_input =
    tx.Input {
      output_reference: reward_transport_ref,
      output: mock_empty_reward_transport_output,
    }
  let reward_transport_output =
    tx.Output {
      address: address.from_script(mock_manager_script_hash),
      value: assets.merge(
        mock_reward_transport_token_value,
        assets.from_asset(
          mock_fee_token_policy_id,
          mock_fee_token_name,
          convert_to_rate(mock_minimum_fee_amount),
        ),
      ),
      datum: tx.InlineDatum(reward_transport_after),
      reference_script: None,
    }

  let odv_aggregate_redeemer: Data = OdvAggregate
  let aggregation_tx =
    Transaction {
      ..tx.placeholder,
      reference_inputs: [core_settings_input, c3_rate_input],
      inputs: [reward_transport_input, aggstate_input],
      redeemers: [
        Pair(tx.Spend(aggstate_ref), odv_aggregate_redeemer),
        Pair(tx.Spend(reward_transport_ref), odv_aggregate_redeemer),
      ],
      outputs: [reward_transport_output, aggstate_output],
      validity_range: mock_precise_tx_validity_interval,
      extra_signatories: pairs.keys(mock_nodes),
    }
  oracle.oracle_manager.spend(
    mock_oracle_conf,
    Some(aggstate_before),
    OdvAggregate,
    aggstate_ref,
    aggregation_tx,
  ) && oracle.oracle_manager.spend(
    mock_oracle_conf,
    Some(reward_transport_before),
    OdvAggregate,
    reward_transport_ref,
    aggregation_tx,
  )
}

test successful_reward_calculation() {
  let rewards_value =
    assets.from_asset(
      mock_fee_token_policy_id,
      mock_fee_token_name,
      mock_minimum_fee_amount,
    )

  let reward_transport_ref =
    OutputReference {
      transaction_id: "some odv aggregation tx",
      output_index: 0,
    }
  let reward_transport_before =
    RewardTransport(
      RewardConsensusPending(
        Aggregation {
          oracle_feed: mock_median,
          message: AggregateMessage {
            node_feeds_sorted_by_feed: mock_node_feeds,
            node_feeds_count: mock_node_feeds_count,
            timestamp: mock_current_time,
          },
          node_reward_price: mock_node_fee,
          rewards_amount_paid: mock_minimum_fee_amount,
        },
      ),
    )
  let reward_transport_input =
    tx.Input {
      output_reference: reward_transport_ref,
      output: tx.Output {
        address: address.from_script(mock_manager_script_hash),
        value: assets.merge(mock_reward_transport_token_value, rewards_value),
        datum: tx.InlineDatum(reward_transport_before),
        reference_script: None,
      },
    }

  let reward_account_ref =
    OutputReference {
      transaction_id: "reward account before calculate rewards tx",
      output_index: 0,
    }
  let reward_account_after =
    RewardAccount(RewardAccountDatum(mock_nodes_rewards))
  let reward_account_input =
    tx.Input {
      output_reference: reward_account_ref,
      output: mock_empty_reward_account_output,
    }
  let reward_account_output =
    tx.Output {
      address: address.from_script(mock_manager_script_hash),
      value: assets.merge(mock_reward_account_token_value, rewards_value),
      datum: tx.InlineDatum(reward_account_after),
      reference_script: None,
    }

  let calculate_rewards_redeemer: Data = CalculateRewards
  let rewards_consensus_tx =
    Transaction {
      ..tx.placeholder,
      reference_inputs: [mock_core_settings_input],
      inputs: [reward_account_input, reward_transport_input],
      redeemers: [
        Pair(tx.Spend(reward_account_ref), calculate_rewards_redeemer),
        Pair(tx.Spend(reward_transport_ref), calculate_rewards_redeemer),
      ],
      outputs: [reward_account_output, mock_empty_reward_transport_output],
    }
  oracle.oracle_manager.spend(
    mock_oracle_conf,
    Some(reward_transport_before),
    CalculateRewards,
    reward_transport_ref,
    rewards_consensus_tx,
  ) && oracle.oracle_manager.spend(
    mock_oracle_conf,
    Some(RewardAccount(mock_empty_reward_account_datum)),
    CalculateRewards,
    reward_account_ref,
    rewards_consensus_tx,
  )
}

test successful_reward_calculation_with_ada_fees() {
  let reward_transport_ref =
    OutputReference {
      transaction_id: "some odv aggregation tx",
      output_index: 0,
    }
  let reward_transport_before =
    RewardTransport(
      RewardConsensusPending(
        Aggregation {
          oracle_feed: mock_median,
          message: AggregateMessage {
            node_feeds_sorted_by_feed: mock_node_feeds,
            node_feeds_count: mock_node_feeds_count,
            timestamp: mock_current_time,
          },
          node_reward_price: mock_node_fee,
          rewards_amount_paid: mock_minimum_fee_amount,
        },
      ),
    )
  let reward_transport_input =
    tx.Input {
      output_reference: reward_transport_ref,
      output: tx.Output {
        address: address.from_script(mock_manager_script_hash),
        value: assets.merge(
          mock_reward_transport_token_value,
          assets.from_lovelace(mock_minimum_fee_amount),
        ),
        datum: tx.InlineDatum(reward_transport_before),
        reference_script: None,
      },
    }

  let reward_account_ref =
    OutputReference {
      transaction_id: "reward account before calculate rewards tx",
      output_index: 0,
    }
  let reward_account_after =
    RewardAccount(RewardAccountDatum(mock_nodes_rewards))
  let reward_account_input =
    tx.Input {
      output_reference: reward_account_ref,
      output: tx.Output {
        address: address.from_script(mock_manager_script_hash),
        value: assets.merge(
          mock_reward_account_token_value,
          assets.from_lovelace(mock_utxo_size_safety_buffer),
        ),
        datum: tx.InlineDatum(RewardAccount(mock_empty_reward_account_datum)),
        reference_script: None,
      },
    }
  let reward_account_output =
    tx.Output {
      address: address.from_script(mock_manager_script_hash),
      value: assets.merge(
        mock_reward_account_token_value,
        assets.from_lovelace(
          mock_minimum_fee_amount + mock_utxo_size_safety_buffer,
        ),
      ),
      datum: tx.InlineDatum(reward_account_after),
      reference_script: None,
    }

  let calculate_rewards_redeemer: Data = CalculateRewards
  let rewards_consensus_tx =
    Transaction {
      ..tx.placeholder,
      reference_inputs: [mock_core_settings_input_using_ada_fee],
      inputs: [reward_account_input, reward_transport_input],
      redeemers: [
        Pair(tx.Spend(reward_account_ref), calculate_rewards_redeemer),
        Pair(tx.Spend(reward_transport_ref), calculate_rewards_redeemer),
      ],
      outputs: [reward_account_output, mock_empty_reward_transport_output],
    }
  oracle.oracle_manager.spend(
    mock_oracle_conf_using_ada_fee,
    Some(reward_transport_before),
    CalculateRewards,
    reward_transport_ref,
    rewards_consensus_tx,
  ) && oracle.oracle_manager.spend(
    mock_oracle_conf_using_ada_fee,
    Some(RewardAccount(mock_empty_reward_account_datum)),
    CalculateRewards,
    reward_account_ref,
    rewards_consensus_tx,
  )
}

test successful_reward_calculation_with_multiple_aggregations() {
  let rewards_value =
    assets.from_asset(
      mock_fee_token_policy_id,
      mock_fee_token_name,
      mock_minimum_fee_amount,
    )

  let reward_transport_ref =
    OutputReference {
      transaction_id: "some odv aggregation tx",
      output_index: 0,
    }
  let reward_transport_before =
    RewardTransport(
      RewardConsensusPending(
        Aggregation {
          oracle_feed: mock_median,
          message: AggregateMessage {
            node_feeds_sorted_by_feed: mock_node_feeds,
            node_feeds_count: mock_node_feeds_count,
            timestamp: mock_current_time,
          },
          node_reward_price: mock_node_fee,
          rewards_amount_paid: mock_minimum_fee_amount,
        },
      ),
    )
  let reward_transport_input =
    tx.Input {
      output_reference: reward_transport_ref,
      output: tx.Output {
        address: address.from_script(mock_manager_script_hash),
        value: assets.merge(mock_reward_transport_token_value, rewards_value),
        datum: tx.InlineDatum(reward_transport_before),
        reference_script: None,
      },
    }

  let mock_node_feeds01: Pairs<FeedVkh, NodeFeed> =
    [
      430003, 419990, 430000, 430004, 429997, 430011, 430008, 430013, 429989,
      430001, 430013, 429985, 430004, 430001, 429999, 429992, 429997,
    ]
      |> list.map2(
          mock_nodes,
          _,
          fn(node, feed) { Pair(builtin.fst_pair(node), feed) },
        )
      |> list.sort(
          fn(p1, p2) { int.compare(builtin.snd_pair(p1), builtin.snd_pair(p2)) },
        )
  let reward_transport_ref01 =
    OutputReference {
      transaction_id: "some odv aggregation tx",
      output_index: 1,
    }
  let reward_transport_before01 =
    RewardTransport(
      RewardConsensusPending(
        Aggregation {
          oracle_feed: 430001,
          message: AggregateMessage {
            node_feeds_sorted_by_feed: mock_node_feeds01,
            node_feeds_count: mock_node_feeds_count,
            timestamp: mock_current_time,
          },
          node_reward_price: mock_node_fee,
          rewards_amount_paid: mock_minimum_fee_amount,
        },
      ),
    )
  let reward_transport_input01 =
    tx.Input {
      output_reference: reward_transport_ref01,
      output: tx.Output {
        address: address.from_script(mock_manager_script_hash),
        value: assets.merge(mock_reward_transport_token_value, rewards_value),
        datum: tx.InlineDatum(reward_transport_before01),
        reference_script: None,
      },
    }

  let nodes_rewards =
    [
      mock_node_fee * 2,
      mock_node_fee,
      mock_node_fee * 2,
      mock_node_fee * 2,
      mock_node_fee * 2,
      mock_node_fee * 2,
      mock_node_fee * 2,
      mock_node_fee * 2,
      mock_node_fee * 2,
      mock_node_fee * 2,
      mock_node_fee * 2,
      mock_node_fee,
      mock_node_fee * 2,
      mock_node_fee * 2,
      mock_node_fee,
      mock_node_fee * 2,
      mock_node_fee * 2,
    ]
  let reward_account_ref =
    OutputReference {
      transaction_id: "reward account before calculate rewards tx",
      output_index: 0,
    }
  let reward_account_after = RewardAccount(RewardAccountDatum(nodes_rewards))
  let reward_account_input =
    tx.Input {
      output_reference: reward_account_ref,
      output: mock_empty_reward_account_output,
    }
  let reward_account_output =
    tx.Output {
      address: address.from_script(mock_manager_script_hash),
      value: assets.merge(mock_reward_account_token_value, rewards_value)
        |> assets.merge(rewards_value),
      datum: tx.InlineDatum(reward_account_after),
      reference_script: None,
    }

  let calculate_rewards_redeemer: Data = CalculateRewards
  let rewards_consensus_tx =
    Transaction {
      ..tx.placeholder,
      reference_inputs: [mock_core_settings_input],
      inputs: [
        reward_account_input, reward_transport_input01, reward_transport_input,
      ],
      redeemers: [
        Pair(tx.Spend(reward_account_ref), calculate_rewards_redeemer),
        Pair(tx.Spend(reward_transport_ref), calculate_rewards_redeemer),
        Pair(tx.Spend(reward_transport_ref01), calculate_rewards_redeemer),
      ],
      outputs: [
        reward_account_output, mock_empty_reward_transport_output,
        mock_empty_reward_transport_output,
      ],
    }
  oracle.oracle_manager.spend(
    mock_oracle_conf,
    Some(reward_transport_before),
    CalculateRewards,
    reward_transport_ref,
    rewards_consensus_tx,
  ) && oracle.oracle_manager.spend(
    mock_oracle_conf,
    Some(RewardAccount(mock_empty_reward_account_datum)),
    CalculateRewards,
    reward_account_ref,
    rewards_consensus_tx,
  )
}

test successful_node_collect() {
  let reward_account_ref =
    OutputReference {
      transaction_id: "reward account before node collect tx",
      output_index: 0,
    }
  let reward_account_before =
    RewardAccount(RewardAccountDatum(mock_nodes_rewards))
  let rewards_value_before =
    assets.from_asset(
      mock_fee_token_policy_id,
      mock_fee_token_name,
      mock_minimum_fee_amount,
    )
  expect (init, [_, ..tail]) = list.span(mock_nodes_rewards, 4)
  let reward_account_after =
    RewardAccount(RewardAccountDatum(list.concat(init, [0, ..tail])))
  let rewards_value_after =
    assets.from_asset(
      mock_fee_token_policy_id,
      mock_fee_token_name,
      mock_minimum_fee_amount - mock_node_fee,
    )
  let reward_account_input =
    tx.Input {
      output_reference: reward_account_ref,
      output: tx.Output {
        address: address.from_script(mock_manager_script_hash),
        value: assets.merge(
          mock_reward_account_token_value,
          rewards_value_before,
        ),
        datum: tx.InlineDatum(reward_account_before),
        reference_script: None,
      },
    }
  let reward_account_output =
    tx.Output {
      address: address.from_script(mock_manager_script_hash),
      value: assets.merge(mock_reward_account_token_value, rewards_value_after),
      datum: tx.InlineDatum(reward_account_after),
      reference_script: None,
    }

  let node_collect_redeemer: Data = NodeCollect
  let node_collect_tx =
    Transaction {
      ..tx.placeholder,
      reference_inputs: [mock_core_settings_input],
      inputs: [reward_account_input],
      redeemers: [Pair(tx.Spend(reward_account_ref), node_collect_redeemer)],
      outputs: [reward_account_output],
      extra_signatories: ["node05 PaymentVkh"],
    }
  oracle.oracle_manager.spend(
    mock_oracle_conf,
    Some(reward_account_before),
    NodeCollect,
    reward_account_ref,
    node_collect_tx,
  )
}

test successful_platform_collect() {
  let reward_account_ref =
    OutputReference {
      transaction_id: "reward account before platform collect tx",
      output_index: 0,
    }
  let reward_account = RewardAccount(RewardAccountDatum(mock_nodes_rewards))
  let rewards_value_before =
    assets.from_asset(
      mock_fee_token_policy_id,
      mock_fee_token_name,
      mock_minimum_fee_amount,
    )
  let rewards_value_after =
    assets.from_asset(
      mock_fee_token_policy_id,
      mock_fee_token_name,
      mock_minimum_fee_amount - mock_platform_fee,
    )
  let reward_account_input =
    tx.Input {
      output_reference: reward_account_ref,
      output: tx.Output {
        address: address.from_script(mock_manager_script_hash),
        value: assets.merge(
          mock_reward_account_token_value,
          rewards_value_before,
        ),
        datum: tx.InlineDatum(reward_account),
        reference_script: None,
      },
    }
  let reward_account_output =
    tx.Output {
      address: address.from_script(mock_manager_script_hash),
      value: assets.merge(mock_reward_account_token_value, rewards_value_after),
      datum: tx.InlineDatum(reward_account),
      reference_script: None,
    }

  let platform_collect_redeemer: Data = PlatformCollect
  let platform_collect_tx =
    Transaction {
      ..tx.placeholder,
      reference_inputs: [mock_core_settings_input],
      inputs: [reward_account_input, mock_platform_nft_input],
      redeemers: [Pair(tx.Spend(reward_account_ref), platform_collect_redeemer)],
      outputs: [reward_account_output, mock_platform_nft_output],
    }
  oracle.oracle_manager.spend(
    mock_oracle_conf,
    Some(reward_account),
    PlatformCollect,
    reward_account_ref,
    platform_collect_tx,
  )
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
      output: mock_core_settings_output,
    }
  let core_settings_after =
    OracleSettingsDatum {
      ..mock_oracle_settings,
      aggregation_liveness_period: thirty_minutes,
      iqr_fence_multiplier: 170,
    }
  let core_settings_output =
    tx.Output {
      address: address.from_script(mock_manager_script_hash),
      value: mock_core_settings_token_value,
      datum: tx.InlineDatum(OracleSettings(core_settings_after)),
      reference_script: None,
    }

  let update_settings_redeemer: Data = UpdateSettings
  let update_settings_tx =
    Transaction {
      ..tx.placeholder,
      inputs: [core_settings_input, mock_platform_nft_input],
      redeemers: [Pair(tx.Spend(core_settings_ref), update_settings_redeemer)],
      outputs: [core_settings_output, mock_platform_nft_output],
    }
  oracle.oracle_manager.spend(
    mock_oracle_conf,
    Some(OracleSettings(mock_oracle_settings)),
    UpdateSettings,
    core_settings_ref,
    update_settings_tx,
  )
}

test successful_set_fee_config() {
  let core_settings_ref =
    OutputReference {
      transaction_id: "core settings before set fee config tx",
      output_index: 0,
    }
  let core_settings_before =
    OracleSettingsDatum {
      ..mock_oracle_settings,
      closing_period_started_at: Some(mock_current_time),
    }
  let core_settings_input =
    tx.Input {
      output_reference: core_settings_ref,
      output: tx.Output {
        address: address.from_script(mock_manager_script_hash),
        value: mock_core_settings_token_value,
        datum: tx.InlineDatum(OracleSettings(core_settings_before)),
        reference_script: None,
      },
    }
  let core_settings_after =
    OracleSettingsDatum {
      ..core_settings_before,
      fee_info: FeeConfig {
        rate_nft: Some(mock_rate_nft),
        reward_prices: RewardPrices {
          node_fee: mock_node_fee / 10,
          platform_fee: mock_platform_fee / 10,
        },
      },
    }
  let core_settings_output =
    tx.Output {
      address: address.from_script(mock_manager_script_hash),
      value: mock_core_settings_token_value,
      datum: tx.InlineDatum(OracleSettings(core_settings_after)),
      reference_script: None,
    }

  let set_fee_config_redeemer: Data = SetFeeConfig
  let set_fee_config_tx =
    Transaction {
      ..tx.placeholder,
      inputs: [core_settings_input, mock_platform_nft_input],
      redeemers: [Pair(tx.Spend(core_settings_ref), set_fee_config_redeemer)],
      outputs: [core_settings_output, mock_platform_nft_output],
    }
  oracle.oracle_manager.spend(
    mock_oracle_conf,
    Some(OracleSettings(core_settings_before)),
    SetFeeConfig,
    core_settings_ref,
    set_fee_config_tx,
  )
}

test successful_add_nodes() {
  let reward_account_ref =
    OutputReference {
      transaction_id: "reward account before add nodes tx",
      output_index: 0,
    }
  let reward_account_before =
    RewardAccount(RewardAccountDatum(mock_nodes_rewards))
  let reward_account_after =
    RewardAccount(
      RewardAccountDatum([0, ..list.concat(mock_nodes_rewards, [0])]),
    )
  let rewards_value =
    assets.from_asset(
      mock_fee_token_policy_id,
      mock_fee_token_name,
      mock_minimum_fee_amount,
    )
  let reward_account_input =
    tx.Input {
      output_reference: reward_account_ref,
      output: tx.Output {
        address: address.from_script(mock_manager_script_hash),
        value: assets.merge(mock_reward_account_token_value, rewards_value),
        datum: tx.InlineDatum(reward_account_before),
        reference_script: None,
      },
    }
  let reward_account_output =
    tx.Output {
      address: address.from_script(mock_manager_script_hash),
      value: assets.merge(mock_reward_account_token_value, rewards_value),
      datum: tx.InlineDatum(reward_account_after),
      reference_script: None,
    }

  let core_settings_ref =
    OutputReference {
      transaction_id: "core settings before add nodes tx",
      output_index: 0,
    }
  let core_settings_before =
    OracleSettingsDatum {
      ..mock_oracle_settings,
      closing_period_started_at: Some(mock_current_time),
    }
  let core_settings_input =
    tx.Input {
      output_reference: core_settings_ref,
      output: tx.Output {
        address: address.from_script(mock_manager_script_hash),
        value: mock_core_settings_token_value,
        datum: tx.InlineDatum(OracleSettings(core_settings_before)),
        reference_script: None,
      },
    }
  let core_settings_after =
    OracleSettingsDatum {
      ..core_settings_before,
      nodes: [
        Pair("node00 FeedVkh", "node00 PaymentVkh"),
        ..list.concat(mock_nodes, [Pair("node18 FeedVkh", "node18 PaymentVkh")])
      ],
      required_node_signatures_count: mock_node_feeds_count + 2,
    }
  let core_settings_output =
    tx.Output {
      address: address.from_script(mock_manager_script_hash),
      value: mock_core_settings_token_value,
      datum: tx.InlineDatum(OracleSettings(core_settings_after)),
      reference_script: None,
    }

  let add_nodes_redeemer: Data = AddNodes
  let add_nodes_tx =
    Transaction {
      ..tx.placeholder,
      inputs: [
        core_settings_input, reward_account_input, mock_platform_nft_input,
      ],
      redeemers: [
        Pair(tx.Spend(core_settings_ref), add_nodes_redeemer),
        Pair(tx.Spend(reward_account_ref), add_nodes_redeemer),
      ],
      outputs: [
        core_settings_output, reward_account_output, mock_platform_nft_output,
      ],
    }
  oracle.oracle_manager.spend(
    mock_oracle_conf,
    Some(reward_account_before),
    AddNodes,
    reward_account_ref,
    add_nodes_tx,
  ) && oracle.oracle_manager.spend(
    mock_oracle_conf,
    Some(OracleSettings(core_settings_before)),
    AddNodes,
    core_settings_ref,
    add_nodes_tx,
  )
}

test successful_del_nodes() {
  let reward_account_ref =
    OutputReference {
      transaction_id: "reward account before del nodes tx",
      output_index: 0,
    }
  let reward_account_before =
    RewardAccount(RewardAccountDatum(mock_nodes_rewards))
  let reward_account_after =
    RewardAccount(RewardAccountDatum(list.drop(mock_nodes_rewards, 1)))
  let rewards_value =
    assets.from_asset(
      mock_fee_token_policy_id,
      mock_fee_token_name,
      mock_minimum_fee_amount,
    )
  let reward_account_input =
    tx.Input {
      output_reference: reward_account_ref,
      output: tx.Output {
        address: address.from_script(mock_manager_script_hash),
        value: assets.merge(mock_reward_account_token_value, rewards_value),
        datum: tx.InlineDatum(reward_account_before),
        reference_script: None,
      },
    }
  let reward_account_output =
    tx.Output {
      address: address.from_script(mock_manager_script_hash),
      value: assets.merge(mock_reward_account_token_value, rewards_value),
      datum: tx.InlineDatum(reward_account_after),
      reference_script: None,
    }

  let core_settings_ref =
    OutputReference {
      transaction_id: "core settings before del nodes tx",
      output_index: 0,
    }
  let core_settings_before =
    OracleSettingsDatum {
      ..mock_oracle_settings,
      closing_period_started_at: Some(mock_current_time),
    }
  let core_settings_input =
    tx.Input {
      output_reference: core_settings_ref,
      output: tx.Output {
        address: address.from_script(mock_manager_script_hash),
        value: mock_core_settings_token_value,
        datum: tx.InlineDatum(OracleSettings(core_settings_before)),
        reference_script: None,
      },
    }
  let core_settings_after =
    OracleSettingsDatum {
      ..core_settings_before,
      nodes: list.delete(
        mock_nodes,
        Pair("node02 FeedVkh", "node02 PaymentVkh"),
      ),
      required_node_signatures_count: mock_node_feeds_count - 1,
    }
  let core_settings_output =
    tx.Output {
      address: address.from_script(mock_manager_script_hash),
      value: mock_core_settings_token_value,
      datum: tx.InlineDatum(OracleSettings(core_settings_after)),
      reference_script: None,
    }

  let del_nodes_redeemer: Data = DelNodes
  let del_nodes_tx =
    Transaction {
      ..tx.placeholder,
      inputs: [
        core_settings_input, reward_account_input, mock_platform_nft_input,
      ],
      redeemers: [
        Pair(tx.Spend(core_settings_ref), del_nodes_redeemer),
        Pair(tx.Spend(reward_account_ref), del_nodes_redeemer),
      ],
      outputs: [
        core_settings_output, reward_account_output, mock_platform_nft_output,
      ],
    }
  oracle.oracle_manager.spend(
    mock_oracle_conf,
    Some(reward_account_before),
    DelNodes,
    reward_account_ref,
    del_nodes_tx,
  ) && oracle.oracle_manager.spend(
    mock_oracle_conf,
    Some(OracleSettings(core_settings_before)),
    DelNodes,
    core_settings_ref,
    del_nodes_tx,
  )
}

test successful_scale_up() {
  let minted_tokens_value =
    assets.from_asset_list(
      [
        Pair(
          mock_oracle_nft_script_hash,
          [
            Pair(config.aggstate_token_name, 2),
            Pair(config.reward_transport_token_name, 2),
          ],
        ),
      ],
    )
  let reward_transport_outputs = mock_empty_reward_transport_outputs(2)
  let aggstate_outputs = mock_empty_aggstate_outputs(2)

  let scale_up_tx =
    Transaction {
      ..tx.placeholder,
      reference_inputs: [mock_core_settings_input],
      inputs: [mock_platform_nft_input],
      outputs: [
        mock_platform_nft_output,
        ..list.concat(aggstate_outputs, reward_transport_outputs)
      ],
      mint: minted_tokens_value,
    }
  oracle.oracle_nfts.mint(
    mock_starting_platform_utxo,
    mock_oracle_conf,
    mock_manager_script_hash,
    ScaleToken,
    mock_oracle_nft_script_hash,
    scale_up_tx,
  )
}

test successful_scale_down() {
  let burned_tokens_value =
    assets.from_asset_list(
      [
        Pair(
          mock_oracle_nft_script_hash,
          [
            Pair(config.aggstate_token_name, -1),
            Pair(config.reward_transport_token_name, -1),
          ],
        ),
      ],
    )
  let reward_transport_ref =
    OutputReference { transaction_id: "before scale down tx", output_index: 0 }
  let reward_transport_input =
    tx.Input {
      output_reference: reward_transport_ref,
      output: mock_empty_reward_transport_output,
    }
  let aggstate_ref =
    OutputReference { transaction_id: "before scale down tx", output_index: 1 }
  let aggstate =
    AggState(
      Some(
        AggStateDatum {
          oracle_feed: mock_median,
          expiry_timestamp: mock_current_time + one_hour,
          created_at: mock_current_time,
        },
      ),
    )
  let aggstate_input =
    tx.Input {
      output_reference: aggstate_ref,
      output: tx.Output {
        address: address.from_script(mock_manager_script_hash),
        value: mock_aggstate_token_value,
        datum: tx.InlineDatum(aggstate),
        reference_script: None,
      },
    }

  let scale_down_redeemer: Data = ScaleDown
  let scale_down_tx =
    Transaction {
      ..tx.placeholder,
      inputs: [mock_platform_nft_input, aggstate_input, reward_transport_input],
      redeemers: [
        Pair(tx.Spend(aggstate_ref), scale_down_redeemer),
        Pair(tx.Spend(reward_transport_ref), scale_down_redeemer),
      ],
      outputs: [mock_platform_nft_output],
      mint: burned_tokens_value,
      validity_range: interval.after(mock_current_time + twenty_four_hours),
    }
  oracle.oracle_nfts.mint(
    mock_starting_platform_utxo,
    mock_oracle_conf,
    mock_manager_script_hash,
    ScaleToken,
    mock_oracle_nft_script_hash,
    scale_down_tx,
  ) && oracle.oracle_manager.spend(
    mock_oracle_conf,
    Some(RewardTransport(NoRewards)),
    ScaleDown,
    reward_transport_ref,
    scale_down_tx,
  ) && oracle.oracle_manager.spend(
    mock_oracle_conf,
    Some(aggstate),
    ScaleDown,
    aggstate_ref,
    scale_down_tx,
  )
}

test successful_scale_down_when_aggstate_is_empty() {
  let burned_tokens_value =
    assets.from_asset_list(
      [
        Pair(
          mock_oracle_nft_script_hash,
          [
            Pair(config.aggstate_token_name, -1),
            Pair(config.reward_transport_token_name, -1),
          ],
        ),
      ],
    )
  let reward_transport_ref =
    OutputReference { transaction_id: "before scale down tx", output_index: 0 }
  let reward_transport_input =
    tx.Input {
      output_reference: reward_transport_ref,
      output: mock_empty_reward_transport_output,
    }
  let aggstate_ref =
    OutputReference { transaction_id: "before scale down tx", output_index: 1 }
  let aggstate = AggState(None)
  let aggstate_input =
    tx.Input {
      output_reference: aggstate_ref,
      output: tx.Output {
        address: address.from_script(mock_manager_script_hash),
        value: mock_aggstate_token_value,
        datum: tx.InlineDatum(aggstate),
        reference_script: None,
      },
    }

  let scale_down_redeemer: Data = ScaleDown
  let scale_down_tx =
    Transaction {
      ..tx.placeholder,
      inputs: [mock_platform_nft_input, aggstate_input, reward_transport_input],
      redeemers: [
        Pair(tx.Spend(aggstate_ref), scale_down_redeemer),
        Pair(tx.Spend(reward_transport_ref), scale_down_redeemer),
      ],
      outputs: [mock_platform_nft_output],
      mint: burned_tokens_value,
      validity_range: interval.after(mock_current_time + twenty_four_hours),
    }
  oracle.oracle_nfts.mint(
    mock_starting_platform_utxo,
    mock_oracle_conf,
    mock_manager_script_hash,
    ScaleToken,
    mock_oracle_nft_script_hash,
    scale_down_tx,
  ) && oracle.oracle_manager.spend(
    mock_oracle_conf,
    Some(RewardTransport(NoRewards)),
    ScaleDown,
    reward_transport_ref,
    scale_down_tx,
  ) && oracle.oracle_manager.spend(
    mock_oracle_conf,
    Some(aggstate),
    ScaleDown,
    aggstate_ref,
    scale_down_tx,
  )
}

test successful_reward_dismissing() {
  let rewards_value =
    assets.from_asset(
      mock_fee_token_policy_id,
      mock_fee_token_name,
      mock_minimum_fee_amount,
    )
  let reward_transport_ref =
    OutputReference {
      transaction_id: "some odv aggregation tx",
      output_index: 0,
    }
  let reward_transport_before =
    RewardTransport(
      RewardConsensusPending(
        Aggregation {
          oracle_feed: mock_median,
          message: AggregateMessage {
            node_feeds_sorted_by_feed: mock_node_feeds,
            node_feeds_count: mock_node_feeds_count,
            timestamp: mock_current_time,
          },
          node_reward_price: mock_node_fee,
          rewards_amount_paid: mock_minimum_fee_amount,
        },
      ),
    )
  let reward_transport_input =
    tx.Input {
      output_reference: reward_transport_ref,
      output: tx.Output {
        address: address.from_script(mock_manager_script_hash),
        value: assets.merge(mock_reward_transport_token_value, rewards_value),
        datum: tx.InlineDatum(reward_transport_before),
        reference_script: None,
      },
    }

  let dismiss_rewards_redeemer: Data = DismissRewards
  let dismiss_rewards_tx =
    Transaction {
      ..tx.placeholder,
      inputs: [reward_transport_input, mock_platform_nft_input],
      redeemers: [
        Pair(tx.Spend(reward_transport_ref), dismiss_rewards_redeemer),
      ],
      outputs: [mock_empty_reward_transport_output, mock_platform_nft_output],
      validity_range: interval.after(mock_current_time + 2 * twenty_four_hours),
    }
  oracle.oracle_manager.spend(
    mock_oracle_conf,
    Some(reward_transport_before),
    DismissRewards,
    reward_transport_ref,
    dismiss_rewards_tx,
  )
}

test successful_oracle_close() {
  let core_settings_ref =
    OutputReference {
      transaction_id: "core settings before oracle close tx",
      output_index: 0,
    }
  let core_settings_input =
    tx.Input {
      output_reference: core_settings_ref,
      output: mock_core_settings_output,
    }
  let core_settings_after =
    OracleSettingsDatum {
      ..mock_oracle_settings,
      closing_period_started_at: Some(mock_current_time),
    }
  let core_settings_output =
    tx.Output {
      address: address.from_script(mock_manager_script_hash),
      value: mock_core_settings_token_value,
      datum: tx.InlineDatum(OracleSettings(core_settings_after)),
      reference_script: None,
    }

  let oracle_close_redeemer: Data = CloseOracle
  let oracle_close_tx =
    Transaction {
      ..tx.placeholder,
      inputs: [core_settings_input, mock_platform_nft_input],
      redeemers: [Pair(tx.Spend(core_settings_ref), oracle_close_redeemer)],
      outputs: [core_settings_output, mock_platform_nft_output],
      validity_range: mock_precise_tx_validity_interval,
    }
  oracle.oracle_manager.spend(
    mock_oracle_conf,
    Some(OracleSettings(mock_oracle_settings)),
    CloseOracle,
    core_settings_ref,
    oracle_close_tx,
  )
}

test successful_reopen_oracle() {
  let core_settings_ref =
    OutputReference {
      transaction_id: "core settings before reopen oracle tx",
      output_index: 0,
    }
  let core_settings_before =
    OracleSettingsDatum {
      ..mock_oracle_settings,
      closing_period_started_at: Some(mock_current_time),
    }
  let core_settings_input =
    tx.Input {
      output_reference: core_settings_ref,
      output: tx.Output {
        address: address.from_script(mock_manager_script_hash),
        value: mock_core_settings_token_value,
        datum: tx.InlineDatum(OracleSettings(core_settings_before)),
        reference_script: None,
      },
    }

  let reopen_oracle_redeemer: Data = ReopenOracle
  let reopen_oracle_tx =
    Transaction {
      ..tx.placeholder,
      inputs: [core_settings_input, mock_platform_nft_input],
      redeemers: [Pair(tx.Spend(core_settings_ref), reopen_oracle_redeemer)],
      outputs: [mock_core_settings_output, mock_platform_nft_output],
    }
  oracle.oracle_manager.spend(
    mock_oracle_conf,
    Some(OracleSettings(core_settings_before)),
    ReopenOracle,
    core_settings_ref,
    reopen_oracle_tx,
  )
}

test successful_remove_oracle() {
  let remove_oracle_redeemer: Data = RemoveOracle
  let burned_tokens_value =
    assets.from_asset_list(
      [
        Pair(
          mock_oracle_nft_script_hash,
          [
            Pair(config.aggstate_token_name, -3),
            Pair(config.core_settings_token_name, -1),
            Pair(config.reward_account_token_name, -1),
            Pair(config.reward_transport_token_name, -3),
          ],
        ),
      ],
    )

  let core_settings_ref =
    OutputReference {
      transaction_id: "core settings before remove oracle tx",
      output_index: 0,
    }
  let core_settings =
    OracleSettingsDatum {
      ..mock_oracle_settings,
      closing_period_started_at: Some(mock_current_time),
    }
  let core_settings_input =
    tx.Input {
      output_reference: core_settings_ref,
      output: tx.Output {
        address: address.from_script(mock_manager_script_hash),
        value: mock_core_settings_token_value,
        datum: tx.InlineDatum(OracleSettings(core_settings)),
        reference_script: None,
      },
    }

  let reward_account_ref =
    OutputReference {
      transaction_id: "reward account before remove oracle tx",
      output_index: 0,
    }
  let reward_account_input =
    tx.Input {
      output_reference: reward_account_ref,
      output: mock_empty_reward_account_output,
    }

  let reward_transport_tx_id = "reward transport before remove oracle tx"
  let reward_transport_inputs =
    mock_empty_reward_transport_outputs(3)
      |> list.indexed_map(
          fn(ix, output) {
            tx.Input {
              output_reference: OutputReference {
                transaction_id: reward_transport_tx_id,
                output_index: ix,
              },
              output,
            }
          },
        )
  let reward_transport_redeemers =
    list.map(
      list.range(0, 2),
      fn(ix) {
        Pair(
          tx.Spend(
            OutputReference {
              transaction_id: reward_transport_tx_id,
              output_index: ix,
            },
          ),
          remove_oracle_redeemer,
        )
      },
    )

  let aggstate_tx_id = "aggstate before remove oracle tx"
  let aggstate_inputs =
    mock_empty_aggstate_outputs(3)
      |> list.indexed_map(
          fn(ix, output) {
            tx.Input {
              output_reference: OutputReference {
                transaction_id: aggstate_tx_id,
                output_index: ix,
              },
              output,
            }
          },
        )
  let aggstate_redeemers =
    list.map(
      list.range(0, 2),
      fn(ix) {
        Pair(
          tx.Spend(
            OutputReference { transaction_id: aggstate_tx_id, output_index: ix },
          ),
          remove_oracle_redeemer,
        )
      },
    )

  let remove_oracle_tx =
    Transaction {
      ..tx.placeholder,
      inputs: [
        core_settings_input, reward_account_input, mock_platform_nft_input,
        ..list.concat(aggstate_inputs, reward_transport_inputs)
      ],
      redeemers: [
        Pair(tx.Spend(core_settings_ref), remove_oracle_redeemer),
        Pair(tx.Spend(reward_account_ref), remove_oracle_redeemer),
        ..list.concat(aggstate_redeemers, reward_transport_redeemers)
      ],
      outputs: [mock_platform_nft_output],
      mint: burned_tokens_value,
      validity_range: interval.after(mock_current_time + 2 * twenty_four_hours),
    }
  oracle.oracle_nfts.mint(
    mock_starting_platform_utxo,
    mock_oracle_conf,
    mock_manager_script_hash,
    BurnToken,
    mock_oracle_nft_script_hash,
    remove_oracle_tx,
  ) && oracle.oracle_manager.spend(
    mock_oracle_conf,
    Some(RewardAccount(mock_empty_reward_account_datum)),
    RemoveOracle,
    reward_account_ref,
    remove_oracle_tx,
  ) && oracle.oracle_manager.spend(
    mock_oracle_conf,
    Some(RewardTransport(NoRewards)),
    RemoveOracle,
    OutputReference { transaction_id: reward_transport_tx_id, output_index: 0 },
    remove_oracle_tx,
  ) && oracle.oracle_manager.spend(
    mock_oracle_conf,
    Some(AggState(None)),
    RemoveOracle,
    OutputReference { transaction_id: aggstate_tx_id, output_index: 0 },
    remove_oracle_tx,
  ) && oracle.oracle_manager.spend(
    mock_oracle_conf,
    Some(OracleSettings(core_settings)),
    RemoveOracle,
    core_settings_ref,
    remove_oracle_tx,
  )
}

test successful_remove_oracle_when_no_aggstate_removed() {
  let remove_oracle_redeemer: Data = RemoveOracle
  let burned_tokens_value =
    assets.from_asset_list(
      [
        Pair(
          mock_oracle_nft_script_hash,
          [
            Pair(config.core_settings_token_name, -1),
            Pair(config.reward_account_token_name, -1),
          ],
        ),
      ],
    )

  let core_settings_ref =
    OutputReference {
      transaction_id: "core settings before remove oracle tx",
      output_index: 0,
    }
  let core_settings =
    OracleSettingsDatum {
      ..mock_oracle_settings,
      closing_period_started_at: Some(mock_current_time),
    }
  let core_settings_input =
    tx.Input {
      output_reference: core_settings_ref,
      output: tx.Output {
        address: address.from_script(mock_manager_script_hash),
        value: mock_core_settings_token_value,
        datum: tx.InlineDatum(OracleSettings(core_settings)),
        reference_script: None,
      },
    }

  let reward_account_ref =
    OutputReference {
      transaction_id: "reward account before remove oracle tx",
      output_index: 0,
    }
  let reward_account_input =
    tx.Input {
      output_reference: reward_account_ref,
      output: mock_empty_reward_account_output,
    }

  let remove_oracle_tx =
    Transaction {
      ..tx.placeholder,
      inputs: [
        core_settings_input, reward_account_input, mock_platform_nft_input,
      ],
      redeemers: [
        Pair(tx.Spend(core_settings_ref), remove_oracle_redeemer),
        Pair(tx.Spend(reward_account_ref), remove_oracle_redeemer),
      ],
      outputs: [mock_platform_nft_output],
      mint: burned_tokens_value,
      validity_range: interval.after(mock_current_time + 2 * twenty_four_hours),
    }
  oracle.oracle_nfts.mint(
    mock_starting_platform_utxo,
    mock_oracle_conf,
    mock_manager_script_hash,
    BurnToken,
    mock_oracle_nft_script_hash,
    remove_oracle_tx,
  ) && oracle.oracle_manager.spend(
    mock_oracle_conf,
    Some(RewardAccount(mock_empty_reward_account_datum)),
    RemoveOracle,
    reward_account_ref,
    remove_oracle_tx,
  ) && oracle.oracle_manager.spend(
    mock_oracle_conf,
    Some(OracleSettings(core_settings)),
    RemoveOracle,
    core_settings_ref,
    remove_oracle_tx,
  )
}
