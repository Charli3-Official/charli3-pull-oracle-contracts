use aiken/crypto.{ScriptHash}
use cardano/address
use cardano/assets.{AssetName, PolicyId}
use cardano/transaction as tx
use core/checks.{check_node_received_reward, check_nodes_update}
use core/datum.{
  FeeConfig, FeedVkh, Nodes, OracleSettingsDatum, RewardAccount,
  RewardAccountDatum, RewardPrices,
}
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

const reward_account_script: ScriptHash = #"ff"

const reward_account_address = address.from_script(reward_account_script)

const fee_policy_id: PolicyId = #"feed"

const fee_asset_name: AssetName = #"c3"

const fee_token_asset = Asset { policy_id: fee_policy_id, name: fee_asset_name }

test add_nodes_succeeds() {
  let before = mk_settings([node_a, node_b], 1)
  let after = mk_settings([node_a, node_b, node_c], 1)

  check_nodes_update(before, after, AddNodes)
}

test del_nodes_succeeds() {
  let before = mk_settings([node_a, node_b], 1)
  let after = mk_settings([node_a], 1)

  check_nodes_update(before, after, DelNodes)
}

test add_nodes_fails_when_unsorted() fail {
  let before = mk_settings([node_a, node_c], 1)
  let after = mk_settings([node_c, node_a], 1)

  check_nodes_update(before, after, AddNodes)
}

test del_nodes_requires_removal() {
  let before = mk_settings([node_a, node_b], 1)
  let after = mk_settings([node_a, node_b], 1)

  !check_nodes_update(before, after, DelNodes)
}

test add_nodes_fails_when_zero_signatories() {
  let before = mk_settings([node_a, node_b], 1)
  let after = mk_settings([node_a, node_b, node_c], 0)

  !check_nodes_update(before, after, AddNodes)
}

// NodeCollect
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

test node_collect_fails_when_lovelace_decreases() {
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

  !check_node_received_reward(
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
