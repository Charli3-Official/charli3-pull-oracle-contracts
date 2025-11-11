use aiken/crypto.{ScriptHash}
use cardano/address
use cardano/assets.{AssetName, PolicyId}
use cardano/transaction as tx
use core/checks.{
  check_node_received_reward, check_nodes_update, check_reward_distribution,
  get_length_and_check_strict_order,
}
use core/datum.{
  AggregateMessage, FeeConfig, FeedVkh, Nodes, OracleSettingsDatum,
  RewardAccount, RewardAccountDatum, RewardPrices,
}
use core/multisig.{check_nodes_multisig}
use core/redeemer.{AddNodes, DelNodes}
use ext/cardano/value.{Asset}

fn mk_settings(nodes: Nodes, sigs: Int) -> OracleSettingsDatum {
  OracleSettingsDatum {
    nodes,
    required_node_signatures_count: sigs,
    fee_info: FeeConfig {
      rate_nft: None,
      reward_prices: RewardPrices { node_fee: 0, platform_fee: 0 },
    },
    aggregation_liveness_period: 0,
    time_uncertainty_aggregation: 0,
    time_uncertainty_platform: 1,
    iqr_fence_multiplier: 150,
    median_divergency_factor: 10,
    utxo_size_safety_buffer: 2,
    pause_period_started_at: None,
  }
}

const node_a: FeedVkh = #"01"

const node_b: FeedVkh = #"02"

const node_c: FeedVkh = #"03"

const node_d: FeedVkh = #"04"

const reward_account_script: ScriptHash = #"ff"

const reward_account_address = address.from_script(reward_account_script)

const fee_policy_id: PolicyId = #"feed"

const fee_asset_name: AssetName = #"c3"

const fee_token_asset = Asset { policy_id: fee_policy_id, name: fee_asset_name }

// ManageSettings :: AddNodes
test add_nodes_succeeds() {
  let before = mk_settings([node_a, node_b], 1)
  let after = mk_settings([node_a, node_b, node_c], 1)

  check_nodes_update(before, after, AddNodes)
}

test add_nodes_fails_when_unsorted() fail {
  let before = mk_settings([node_a, node_c], 1)
  let after = mk_settings([node_c, node_a], 1)

  check_nodes_update(before, after, AddNodes)
}

test add_nodes_fails_when_zero_signatories() fail {
  let before = mk_settings([node_a, node_b], 1)
  let after = mk_settings([node_a, node_b, node_c], 0)

  check_nodes_update(before, after, AddNodes)
}

// ManageSettings :: DelNodes
test del_nodes_succeeds() {
  let before = mk_settings([node_a, node_b], 1)
  let after = mk_settings([node_a], 1)

  check_nodes_update(before, after, DelNodes)
}

test del_nodes_requires_removal() fail {
  let before = mk_settings([node_a, node_b], 1)
  let after = mk_settings([node_a, node_b], 1)

  check_nodes_update(before, after, DelNodes)
}

// RewardRedeemer :: NodeCollect
test node_collect_succeeds_with_fee_token() {
  let utxo_size_safety_buffer = 5_000_000
  let in_distribution =
    RewardAccountDatum {
      nodes_to_rewards: [Pair(node_a, 5), Pair(node_b, 3)],
      last_update_time: 42,
    }
  let in_value =
    assets.merge(
      assets.from_lovelace(utxo_size_safety_buffer),
      assets.from_asset(fee_policy_id, fee_asset_name, 8),
    )
  let out_distribution =
    RewardAccountDatum {
      nodes_to_rewards: [Pair(node_b, 3)],
      last_update_time: 42,
    }
  let out_value =
    assets.merge(
      assets.from_lovelace(utxo_size_safety_buffer),
      assets.from_asset(fee_policy_id, fee_asset_name, 3),
    )
  let reward_account_output =
    tx.Output {
      address: reward_account_address,
      value: out_value,
      datum: tx.InlineDatum(RewardAccount(out_distribution)),
      reference_script: None,
    }

  check_node_received_reward(
    Some(fee_token_asset),
    node_a,
    in_distribution,
    in_value,
    reward_account_output,
    utxo_size_safety_buffer,
  )
}

test node_collect_fails_when_lovelace_decreases() fail {
  let utxo_size_safety_buffer = 5_000_000
  let in_distribution =
    RewardAccountDatum {
      nodes_to_rewards: [Pair(node_a, 5), Pair(node_b, 3)],
      last_update_time: 73,
    }
  let in_value =
    assets.merge(
      assets.from_lovelace(utxo_size_safety_buffer),
      assets.from_asset(fee_policy_id, fee_asset_name, 8),
    )
  let out_distribution =
    RewardAccountDatum {
      nodes_to_rewards: [Pair(node_b, 3)],
      last_update_time: 73,
    }
  let out_value =
    assets.merge(
      assets.from_lovelace(utxo_size_safety_buffer - 1),
      assets.from_asset(fee_policy_id, fee_asset_name, 3),
    )
  let reward_account_output =
    tx.Output {
      address: reward_account_address,
      value: out_value,
      datum: tx.InlineDatum(RewardAccount(out_distribution)),
      reference_script: None,
    }

  check_node_received_reward(
    Some(fee_token_asset),
    node_a,
    in_distribution,
    in_value,
    reward_account_output,
    utxo_size_safety_buffer,
  )
}

test node_collect_succeeds_with_ada_rewards() {
  let utxo_size_safety_buffer = 5_000_000
  let in_distribution =
    RewardAccountDatum {
      nodes_to_rewards: [Pair(node_a, 2_000_000), Pair(node_b, 500_000)],
      last_update_time: 99,
    }
  let in_value = assets.from_lovelace(7_500_000)
  let out_distribution =
    RewardAccountDatum {
      nodes_to_rewards: [Pair(node_b, 500_000)],
      last_update_time: 99,
    }
  let out_value = assets.from_lovelace(5_500_000)
  let reward_account_output =
    tx.Output {
      address: reward_account_address,
      value: out_value,
      datum: tx.InlineDatum(RewardAccount(out_distribution)),
      reference_script: None,
    }

  check_node_received_reward(
    None,
    node_a,
    in_distribution,
    in_value,
    reward_account_output,
    utxo_size_safety_buffer,
  )
}

// Aggregate
test reward_distribution_accepts_sorted_output() {
  let node_reward_price = 5
  let node_feeds_sorted_by_feed: AggregateMessage =
    [Pair(node_a, 100), Pair(node_b, 100)]
  let in_distribution = [Pair(node_a, 10), Pair(node_b, 10)]
  let out_distribution = [Pair(node_a, 15), Pair(node_b, 15)]
  let nodes = [node_a, node_b]

  check_reward_distribution(
    node_feeds_sorted_by_feed,
    2,
    100,
    node_reward_price,
    in_distribution,
    out_distribution,
    nodes,
    150,
    300,
  )
}

// check_reward_distribution rejects unsorted out_distributions.
// During the fold, consume_allowed_feed walks the sorted list of nodes in ascending FeedVkh order.
// If the next output feed isn’t the smallest remaining key, it returns None,
// marking the state invalid and failing the predicate.
// So any out-of-order entry breaks the check automatically.

test reward_distribution_rejects_unsorted_output() fail {
  let node_reward_price = 5
  let node_feeds_sorted_by_feed: AggregateMessage =
    [Pair(node_a, 100), Pair(node_b, 100), Pair(node_c, 100)]
  let in_distribution = [Pair(node_a, 10), Pair(node_b, 10), Pair(node_c, 10)]
  let out_distribution = [Pair(node_b, 15), Pair(node_a, 15), Pair(node_c, 15)]
  let nodes = [node_a, node_b, node_c]

  check_reward_distribution(
    node_feeds_sorted_by_feed,
    2,
    100,
    node_reward_price,
    in_distribution,
    out_distribution,
    nodes,
    150,
    300,
  )
}

test check_nodes_multisig_accepts_required_signers() {
  let message: AggregateMessage = [Pair(node_a, 100), Pair(node_b, 105)]
  let signers = [node_a, node_b]
  let allowed_nodes = [node_a, node_b, node_c]

  check_nodes_multisig(message, 2, signers, allowed_nodes, 2)
}

test check_nodes_multisig_rejects_unknown_node() fail {
  let message: AggregateMessage = [Pair(node_a, 100), Pair(node_c, 105)]
  let signers = [node_a, node_c]
  let allowed_nodes = [node_a, node_b]

  check_nodes_multisig(message, 2, signers, allowed_nodes, 2)
}

test reward_distribution_filters_outliers_with_iqr() {
  let node_reward_price = 5
  let node_feeds_sorted_by_feed: AggregateMessage =
    [
      Pair(node_a, 100), Pair(node_b, 101), Pair(node_c, 102),
      Pair(node_d, 1000),
    ]
  let in_distribution =
    [Pair(node_a, 10), Pair(node_b, 10), Pair(node_c, 10), Pair(node_d, 10)]
  let out_distribution =
    [Pair(node_a, 15), Pair(node_b, 15), Pair(node_c, 15), Pair(node_d, 10)]
  let nodes = [node_a, node_b, node_c, node_d]

  check_reward_distribution(
    node_feeds_sorted_by_feed,
    4,
    101,
    node_reward_price,
    in_distribution,
    out_distribution,
    nodes,
    150,
    300,
  )
}

test get_length_and_check_strict_order_succeds() {
  let inst_sorted = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
  expect 12 == get_length_and_check_strict_order(inst_sorted)
}

test get_length_and_check_strict_order_fails() fail {
  let inst_sorted = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 11]
  expect 12 == get_length_and_check_strict_order(inst_sorted)
}
