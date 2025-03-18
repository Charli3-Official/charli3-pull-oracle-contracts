use aiken/builtin
use aiken/collection/dict.{Dict}
use aiken/collection/list
use aiken/collection/pairs
use aiken/crypto.{ScriptHash, VerificationKeyHash}
use aiken/interval
use aiken/math/rational
use aiken/option.{is_some}
use cardano/address.{Address}
use cardano/assets.{PolicyId, Value}
use cardano/transaction.{Input,
  Output, Redeemer, ScriptPurpose, ValidityRange} as tx
use ext/aiken/math/rational.{Percent, Permille, coin_precision} as ext
use ext/aiken/time.{PosixTime, PosixTimeDiff}
use ext/cardano/value.{Asset}
use oracle/consensus.{consensus_by_iqr_and_divergency}
use oracle/datum.{
  AggState, AggregateMessage, Aggregation, FeedVkh, GenericData, NodeFeed, Nodes,
  OracleConfiguration, OracleDatum, OracleFeed, OracleSettingsDatum, PaymentVkh,
  PriceData, RewardAccount, RewardAccountDatum, RewardPrices, get_price_data,
}
use oracle/redeemer.{OdvAggregate, OracleRedeemer}
use services/protocol_token.{
  find_script_inputs_by_token, find_script_outputs_by_token,
  find_script_outputs_by_token_allowing_asset,
}
use services/reward_escrow.{RewardEscrowDatum}

/// A convenience function that calls find_script_inputs_by_token
/// and also checks number of spent inputs
pub fn spends_protocol_nft_inputs(
  script_hash: ScriptHash,
  redeemer: OracleRedeemer,
  protocol_nft: Asset,
  utxo_count: Int,
  tx_inputs: List<Input>,
  tx_redeemers: Pairs<ScriptPurpose, Redeemer>,
) -> Bool {
  trace @"T7"

  let as_data: Data = redeemer
  let refs =
    find_script_inputs_by_token(tx_inputs, script_hash, protocol_nft)
      |> list.map(fn(i) { i.output_reference })

  let refs_that_have_correct_redeemers =
    list.filter(
      refs,
      fn(ref) {
        expect Some(r) = pairs.get_first(tx_redeemers, tx.Spend(ref))

        r == as_data
      },
    )

  list.length(refs_that_have_correct_redeemers) == utxo_count
}

/// Find one protocol NFT inside transaction inputs.
/// Same as spends_protocol_nft_inputs, but more optimized.
pub fn spends_one_script_utxo_with_nft(
  script_hash: ScriptHash,
  redeemer: OracleRedeemer,
  nft: Asset,
  tx_inputs: List<Input>,
  tx_redeemers: Pairs<ScriptPurpose, Redeemer>,
) -> Bool {
  trace @"T8"

  let as_data: Data = redeemer
  expect [input] = find_script_inputs_by_token(tx_inputs, script_hash, nft)
  expect Some(r) =
    pairs.get_first(tx_redeemers, tx.Spend(input.output_reference))

  r == as_data
}

pub fn spends_one_account_utxo_for_aggregation(
  script_hash: ScriptHash,
  acc_nft: Asset,
  tx_inputs: List<Input>,
  tx_redeemers: Pairs<ScriptPurpose, Redeemer>,
) -> Bool {
  trace @"T88"

  expect [input] = find_script_inputs_by_token(tx_inputs, script_hash, acc_nft)
  expect Some(redeemer) =
    pairs.get_first(tx_redeemers, tx.Spend(input.output_reference))
  expect r: OracleRedeemer = redeemer
  expect OdvAggregate(_) = r

  True
}

pub fn returns_empty_account_outputs(
  script_hash: ScriptHash,
  reward_account_nft: Asset,
  utxo_count: Int,
  tx_outputs: List<Output>,
  utxo_size_safety_buffer: Int,
) -> Bool {
  trace @"T9"

  let outputs =
    find_script_outputs_by_token(tx_outputs, script_hash, reward_account_nft)
  let extractor =
    fn(output: Output) -> RewardAccountDatum {
      expect tx.InlineDatum(datum) = output.datum
      expect oracle_datum: OracleDatum = datum
      expect RewardAccount(reward_acc) = oracle_datum

      reward_acc
    }
  expect _ = list.map(outputs, extractor)
  let values = list.map(outputs, fn(out) { out.value })

  list.length(outputs) == utxo_count && list.all(
    values,
    check_utxo_size_safety_buffer(utxo_size_safety_buffer, _),
  )
}

pub fn returns_empty_aggstate_outputs(
  script_hash: ScriptHash,
  aggstate_nft: Asset,
  utxo_count: Int,
  tx_outputs: List<Output>,
) -> Bool {
  trace @"T10"
  let outputs =
    find_script_outputs_by_token(tx_outputs, script_hash, aggstate_nft)
  let extractor =
    fn(output: Output) -> Bool {
      expect tx.InlineDatum(datum) = output.datum
      expect oracle_datum: OracleDatum = datum
      expect AggState(GenericData { price_map }) = oracle_datum
      list.is_empty(price_map)
    }

  list.length(outputs) == utxo_count && list.all(outputs, extractor)
}

pub fn find_out_datum_and_value(
  tx_outputs: List<Output>,
  script_hash: ScriptHash,
  protocol_token: Asset,
) -> (OracleDatum, Value) {
  trace @"T11"

  expect [script_out] =
    find_script_outputs_by_token(tx_outputs, script_hash, protocol_token)
  expect tx.InlineDatum(datum) = script_out.datum
  expect oracle_datum: OracleDatum = datum
  (oracle_datum, script_out.value)
}

pub fn find_out_datum_and_value_with_allowing_asset(
  tx_outputs: List<Output>,
  script_hash: ScriptHash,
  protocol_token: Asset,
  allowed_asset: Option<Asset>,
) -> (OracleDatum, Value) {
  trace @"T12"

  when allowed_asset is {
    None -> find_out_datum_and_value(tx_outputs, script_hash, protocol_token)
    Some(asset) -> {
      expect [script_out] =
        find_script_outputs_by_token_allowing_asset(
          tx_outputs,
          script_hash,
          asset.policy_id,
          protocol_token,
        )
      expect tx.InlineDatum(datum) = script_out.datum
      expect oracle_datum: OracleDatum = datum

      (oracle_datum, script_out.value)
    }
  }
}

pub fn find_referenced_datum(
  tx_reference_inputs: List<Input>,
  script_hash: ScriptHash,
  protocol_token: Asset,
) -> OracleDatum {
  trace @"T13"

  expect [script_in] =
    find_script_inputs_by_token(
      tx_reference_inputs,
      script_hash,
      protocol_token,
    )
  expect tx.InlineDatum(datum) = script_in.output.datum
  expect oracle_datum: OracleDatum = datum

  oracle_datum
}

pub fn find_in_datum(
  tx_inputs: List<Input>,
  tx_redeemers: Pairs<ScriptPurpose, Redeemer>,
  script_hash: ScriptHash,
  redeemer: OracleRedeemer,
  protocol_token: Asset,
) -> OracleDatum {
  trace @"T14"

  expect [script_in] =
    find_script_inputs_by_token(tx_inputs, script_hash, protocol_token)

  let as_data: Data = redeemer
  expect Some(r) =
    pairs.get_first(tx_redeemers, tx.Spend(script_in.output_reference))
  expect r == as_data

  expect tx.InlineDatum(datum) = script_in.output.datum
  expect oracle_datum: OracleDatum = datum

  oracle_datum
}

pub fn does_not_produce_own_nft_outputs(
  tx_outputs: List<Output>,
  own_nft_policy_id: PolicyId,
) -> Bool {
  trace @"T16"

  tx_outputs
    |> list.filter(
        fn(o) {
          o.value |> assets.to_dict |> dict.get(own_nft_policy_id) |> is_some
        },
      )
    |> list.is_empty
}

pub fn is_aggstate_expired(
  price_data: PriceData,
  tx_validity_range: ValidityRange,
) -> Bool {
  trace @"T17"
  get_price_data(price_data, 2)
    |> option.map(
        fn(time_expiration) {
          interval.is_entirely_after(tx_validity_range, time_expiration)
        },
      )
    |> option.or_else(True)
}

pub fn convert_reward_prices(
  tx_reference_inputs: List<Input>,
  tx_validity_range: ValidityRange,
  rate_nft: Option<Asset>,
  reward_prices: RewardPrices,
) -> RewardPrices {
  trace @"T18"

  when rate_nft is {
    None -> reward_prices
    Some(nft) -> {
      expect Some(rate_input) =
        tx_reference_inputs
          |> list.find(
              fn(input) {
                input.output.value
                  |> assets.flatten
                  |> list.has((nft.policy_id, nft.name, 1))
              },
            )
      expect tx.InlineDatum(datum) = rate_input.output.datum
      expect oracle_datum: OracleDatum = datum
      expect AggState(generic_data) = oracle_datum
      expect Some(price) = get_price_data(generic_data, 0)
      expect Some(rate) = rational.new(price, coin_precision)

      expect Some(time_expiration) = get_price_data(generic_data, 2)
      expect interval.is_entirely_before(tx_validity_range, time_expiration)

      let convert_reward =
        fn(reward: Int) -> Int {
          rational.from_int(reward) |> rational.mul(rate) |> rational.ceil
        }

      RewardPrices {
        node_fee: convert_reward(reward_prices.node_fee),
        platform_fee: convert_reward(reward_prices.platform_fee),
      }
    }
  }
}

pub fn calculate_minimum_fee_amount(
  reward_prices: RewardPrices,
  nodes_count: Int,
) -> Int {
  reward_prices.node_fee * nodes_count + reward_prices.platform_fee
}

pub fn calculate_asset_net_change(
  asset: Asset,
  in_value: Value,
  out_value: Value,
) -> Int {
  assets.quantity_of(out_value, asset.policy_id, asset.name) - assets.quantity_of(
    in_value,
    asset.policy_id,
    asset.name,
  )
}

pub fn calculate_asset_net_change_with_default(
  asset: Option<Asset>,
  in_value: Value,
  out_value: Value,
) -> Int {
  option.or_else(
    asset,
    Asset { policy_id: assets.ada_policy_id, name: assets.ada_asset_name },
  )
    |> calculate_asset_net_change(in_value, out_value)
}

pub fn calculate_asset_quantity_with_default(
  value: Value,
  optional_asset: Option<Asset>,
) -> Int {
  when optional_asset is {
    None ->
      assets.quantity_of(value, assets.ada_policy_id, assets.ada_asset_name)
    Some(asset) -> assets.quantity_of(value, asset.policy_id, asset.name)
  }
}

pub fn conserves_utxo_value(in_value: Value, out_value: Value) -> Bool {
  trace @"T23"

  let in_tokens = assets.without_lovelace(in_value)
  let out_tokens = assets.without_lovelace(out_value)
  let must_conserve_token_value = in_tokens == out_tokens

  let in_lovelace = assets.lovelace_of(in_value)
  let out_lovelace = assets.lovelace_of(out_value)
  let must_conserve_ada_value = in_lovelace <= out_lovelace

  must_conserve_token_value && must_conserve_ada_value
}

pub fn check_utxo_size_safety_buffer(
  utxo_size_safety_buffer: Int,
  out_value: Value,
) -> Bool {
  trace @"T32"

  let out_lovelace = assets.lovelace_of(out_value)

  out_lovelace >= utxo_size_safety_buffer
}

pub fn oracle_fees_were_transferred(
  fee_token: Option<Asset>,
  aggregations: List<Aggregation>,
  in_value: Value,
  out_value: Value,
  utxo_size_safety_buffer: Int,
) -> Bool {
  trace @"T19"

  let actual_fee =
    calculate_asset_net_change_with_default(fee_token, in_value, out_value)
  let required_fee =
    list.foldr(
      aggregations,
      0,
      fn(aggregation, acc) { acc + aggregation.rewards_amount_paid },
    )

  check_utxo_size_safety_buffer(utxo_size_safety_buffer, out_value) && actual_fee >= required_fee
}

pub fn check_reward_distribution(
  message: AggregateMessage,
  median: OracleFeed,
  node_reward_price: Int,
  in_distribution: Pairs<PaymentVkh, Int>,
  out_distribution: Pairs<PaymentVkh, Int>,
  nodes: Nodes,
  // Already sorted ascendingly by FeedVkh
  iqr_fence_multiplier: Percent,
  median_divergency_factor: Permille,
) -> Bool {
  trace @"T20"
  // Compute rewarded feed nodes first, as this is needed for validation
  let rewarded_feed_nodes =
    consensus_by_iqr_and_divergency(
      median,
      message.node_feeds_sorted_by_feed,
      message.node_feeds_count,
      iqr_fence_multiplier,
      median_divergency_factor,
    )
  // Create a set of rewarded feed VKHs - using a map for O(1) lookups
  let rewarded_feed_dict =
    list.foldr(
      rewarded_feed_nodes,
      dict.empty,
      fn(feed_vkh, acc) { dict.insert(acc, feed_vkh, True) },
    )
  // Process all records in a single pass to avoid creating of intermediate data structures
  dict.from_ascending_pairs(out_distribution)
    |> dict.foldr(
        True,
        fn(payment_vkh, out_amount, acc) {
          if !acc {
            // Short-circuit if we've already found an invalid case
            False
          } else {
            // Find the feed vkh for this payment vkh
            let maybe_feed_vkh =
              nodes
                |> list.find(fn(Pair(_, snd)) { snd == payment_vkh })
                |> option.map(fn(Pair(fst, _)) { fst })
            when maybe_feed_vkh is {
              // Invalid payment VKH - not in the nodes list
              None -> False
              Some(feed_vkh) -> {
                // Determine expected reward based on whether this feed node was rewarded
                let expected_reward =
                  if dict.has_key(rewarded_feed_dict, feed_vkh) {
                    node_reward_price
                  } else {
                    0
                  }
                // Get input amount, defaulting to 0 if not present
                let in_amount =
                  in_distribution
                    |> list.find(fn(Pair(fst, _)) { fst == payment_vkh })
                    |> option.map(fn(Pair(_, snd)) { snd })
                    |> option.or_else(0)
                // 0 since it's a new node
                // Check if the output amount matches expected
                in_amount + expected_reward == out_amount
              }
            }
          }
        },
      )
}

pub fn validate_message_form(message: AggregateMessage) -> Bool {
  trace @"T21"

  let node_feeds = pairs.values(message.node_feeds_sorted_by_feed)

  let length = get_length_and_check_order(node_feeds)

  length == message.node_feeds_count
}

fn get_length_and_check_order(node_feeds_sorted: List<NodeFeed>) -> Int {
  when node_feeds_sorted is {
    [] -> 0
    [x, ..xs] -> do_get_length_and_check_order(xs, 1, x)
  }
}

fn do_get_length_and_check_order(
  node_feeds_sorted: List<NodeFeed>,
  n: Int,
  prev: NodeFeed,
) -> Int {
  when node_feeds_sorted is {
    [] -> n
    [x, ..xs] ->
      if prev <= x {
        do_get_length_and_check_order(xs, n + 1, x)
      } else {
        fail @"E5"
      }
  }
}

pub fn check_settings_sanity(
  oracle_conf: OracleConfiguration,
  in_settings: OracleSettingsDatum,
  out_settings: OracleSettingsDatum,
) -> Bool {
  trace @"T22"

  in_settings.nodes == out_settings.nodes && in_settings.pause_period_started_at == out_settings.pause_period_started_at && validate_settings_form(
    oracle_conf,
    out_settings,
  )
}

pub fn validate_settings_form(
  oracle_conf: OracleConfiguration,
  oracle_settings: OracleSettingsDatum,
) -> Bool {
  trace @"T30"

  let must_not_break_multisig =
    oracle_settings.required_node_signatures_count > 0 && oracle_settings.required_node_signatures_count <= list.length(
      oracle_settings.nodes,
    )

  let must_measure_time_precisely =
    oracle_settings.aggregation_liveness_period > oracle_settings.time_uncertainty_platform && oracle_conf.pause_period_length > oracle_settings.time_uncertainty_platform && oracle_conf.reward_dismissing_period_length > oracle_settings.time_uncertainty_platform
  let must_have_fair_validity_intervals =
    oracle_settings.time_uncertainty_platform > oracle_settings.time_uncertainty_aggregation && oracle_settings.time_uncertainty_aggregation > 0

  let must_be_fair_about_outliers =
    oracle_settings.iqr_fence_multiplier > 100 && oracle_settings.median_divergency_factor >= 1
  let must_not_have_negative_utxo_buffer =
    oracle_settings.utxo_size_safety_buffer > 0

  let must_not_have_negative_prices =
    oracle_settings.fee_info.reward_prices.node_fee >= 0 && oracle_settings.fee_info.reward_prices.platform_fee >= 0

  must_not_break_multisig && must_measure_time_precisely && must_have_fair_validity_intervals && must_be_fair_about_outliers && must_not_have_negative_utxo_buffer && must_not_have_negative_prices
}

pub fn check_pause_does_not_change_settings(
  in_core_datum: OracleSettingsDatum,
  out_core_datum: OracleSettingsDatum,
) -> Bool {
  trace @"T24"

  in_core_datum.nodes == out_core_datum.nodes && in_core_datum.utxo_size_safety_buffer == out_core_datum.utxo_size_safety_buffer && in_core_datum.iqr_fence_multiplier == out_core_datum.iqr_fence_multiplier && in_core_datum.median_divergency_factor == out_core_datum.median_divergency_factor && in_core_datum.fee_info == out_core_datum.fee_info && in_core_datum.aggregation_liveness_period == out_core_datum.aggregation_liveness_period && in_core_datum.time_uncertainty_platform == out_core_datum.time_uncertainty_platform && in_core_datum.time_uncertainty_aggregation == out_core_datum.time_uncertainty_aggregation
}

pub fn find_node_by_signature(
  tx_signatories: List<VerificationKeyHash>,
  nodes: Nodes,
) -> Option<PaymentVkh> {
  trace @"T25"

  let maybe_node =
    list.find(
      nodes,
      fn(Pair(_, payment_vkh)) { list.has(tx_signatories, payment_vkh) },
    )

  maybe_node |> option.map(fn(Pair(_, payment_vkh)) { payment_vkh })
}

pub fn check_node_received_reward(
  fee_token: Option<Asset>,
  maybe_payment_vkh: Option<PaymentVkh>,
  in_distribution: Pairs<PaymentVkh, Int>,
  out_distribution: Pairs<PaymentVkh, Int>,
  in_value: Value,
  out_value: Value,
) -> Bool {
  trace @"T26"

  when maybe_payment_vkh is {
    None -> False
    Some(payment_vkh) -> {
      // Find the reward amount directly in input distribution
      let maybe_in_amount =
        list.find(in_distribution, fn(Pair(fst, _)) { fst == payment_vkh })
          |> option.map(fn(Pair(_, snd)) { snd })

      // Check that payment_vkh does NOT exist in out_distribution
      let payment_vkh_exists_in_out =
        list.any(out_distribution, fn(Pair(fst, _)) { fst == payment_vkh })

      when maybe_in_amount is {
        None -> False
        Some(required_reward) ->
          if required_reward <= 0 || payment_vkh_exists_in_out {
            False
          } else {
            // Calculate actual reward received
            let actual_reward =
              calculate_asset_net_change_with_default(
                fee_token,
                in_value,
                out_value,
              )
                |> fn(v) { -v }

            // Simply filter out the rewarded node from input and compare the resulting lists
            let in_without_payment_vkh =
              list.filter(
                in_distribution,
                fn(Pair(fst, snd)) { fst != payment_vkh },
              )
            let other_entries_match = in_without_payment_vkh == out_distribution

            // Final verification
            other_entries_match && required_reward == actual_reward
          }
      }
    }
  }
}

pub fn check_platform_received_reward(
  fee_token: Option<Asset>,
  utxo_size_safety_buffer: Int,
  reward_distribution: Pairs<PaymentVkh, Int>,
  in_value: Value,
  out_value: Value,
) -> Bool {
  trace @"T27"

  let nodes_rewards =
    list.foldr(
      reward_distribution,
      0,
      fn(Pair(_, reward), total) { reward + total },
    )

  let in_total_rewards =
    calculate_asset_quantity_with_default(in_value, fee_token)
  let out_total_rewards =
    calculate_asset_quantity_with_default(out_value, fee_token)
  let actual_reward = in_total_rewards - out_total_rewards

  let must_save_nodes_rewards =
    when fee_token is {
      Some(_) ->
        out_total_rewards >= nodes_rewards && check_utxo_size_safety_buffer(
          utxo_size_safety_buffer,
          out_value,
        )
      None -> out_total_rewards - utxo_size_safety_buffer >= nodes_rewards
    }

  let must_withdraw = actual_reward > 0

  must_save_nodes_rewards && must_withdraw
}

// TODO required_node_signatures_count is > 0, but should be > 4 instead when disallow_less_than_four_nodes?
pub fn check_added_nodes(
  in_settings: OracleSettingsDatum,
  out_settings: OracleSettingsDatum,
  in_distribution: List<Int>,
  out_distribution: List<Int>,
) -> Bool {
  trace @"T28"

  let (deleted_nodes, added_nodes) =
    list.foldl(out_settings.nodes, (in_settings.nodes, []), push_added_node)
  let old_distribution_dict =
    list.foldr(
      added_nodes,
      list.map2(
        pairs.keys(out_settings.nodes),
        out_distribution,
        fn(id, reward) { Pair(id, reward) },
      )
        |> dict.from_ascending_pairs,
      check_new_node_rewards_distribution,
    )

  let must_keep_other_settings_unchanged =
    in_settings.fee_info == out_settings.fee_info && in_settings.aggregation_liveness_period == out_settings.aggregation_liveness_period && in_settings.time_uncertainty_platform == out_settings.time_uncertainty_platform && in_settings.time_uncertainty_aggregation == out_settings.time_uncertainty_aggregation && in_settings.iqr_fence_multiplier == out_settings.iqr_fence_multiplier && in_settings.median_divergency_factor == out_settings.median_divergency_factor && in_settings.utxo_size_safety_buffer == out_settings.utxo_size_safety_buffer && in_settings.pause_period_started_at == out_settings.pause_period_started_at
  let must_not_break_multisig =
    out_settings.required_node_signatures_count > 0 && out_settings.required_node_signatures_count <= list.length(
      out_settings.nodes,
    )
  let must_not_delete_nodes = deleted_nodes == []
  let must_add_some_nodes = added_nodes != []
  let must_save_old_nodes =
    dict.values(old_distribution_dict) == in_distribution

  must_keep_other_settings_unchanged && must_not_break_multisig && must_not_delete_nodes && must_add_some_nodes && must_save_old_nodes
}

fn push_added_node(
  node: Pair<FeedVkh, PaymentVkh>,
  acc: (Nodes, Nodes),
) -> (Nodes, Nodes) {
  let (in_nodes, result) = acc
  when in_nodes is {
    [] -> ([], list.push(result, node))
    [x, ..xs] ->
      if x == node {
        (xs, result)
      } else {
        (in_nodes, list.push(result, node))
      }
  }
}

fn check_new_node_rewards_distribution(
  new_node: Pair<FeedVkh, PaymentVkh>,
  out_distribution: Dict<FeedVkh, Int>,
) -> Dict<FeedVkh, Int> {
  expect (Some(0), acc) = dict.pop(out_distribution, builtin.fst_pair(new_node))
  acc
}

// TODO required_node_signatures_count is > 0, but should be > 4 instead when disallow_less_than_four_nodes?
pub fn check_deleted_nodes_returning(
  in_settings: OracleSettingsDatum,
  out_settings: OracleSettingsDatum,
  in_distribution: List<Int>,
  out_distribution: List<Int>,
) -> Nodes {
  trace @"T29"

  let (added_nodes, _, deleted_nodes_ixs, deleted_nodes) =
    list.foldl(
      in_settings.nodes,
      (out_settings.nodes, 0, [], []),
      push_changed_node,
    )
  let (_, expected_distribution) =
    list.indexed_foldr(
      in_distribution,
      (deleted_nodes_ixs, []),
      push_unchanged_node_reward,
    )

  let must_keep_other_settings_unchanged =
    in_settings.fee_info == out_settings.fee_info && in_settings.aggregation_liveness_period == out_settings.aggregation_liveness_period && in_settings.time_uncertainty_platform == out_settings.time_uncertainty_platform && in_settings.time_uncertainty_aggregation == out_settings.time_uncertainty_aggregation && in_settings.iqr_fence_multiplier == out_settings.iqr_fence_multiplier && in_settings.median_divergency_factor == out_settings.median_divergency_factor && in_settings.utxo_size_safety_buffer == out_settings.utxo_size_safety_buffer && in_settings.pause_period_started_at == out_settings.pause_period_started_at
  let must_not_break_multisig =
    out_settings.required_node_signatures_count > 0 && out_settings.required_node_signatures_count <= get_length_and_check_strict_order(
      pairs.keys(out_settings.nodes),
    )
  let must_not_add_nodes = added_nodes == []
  let must_delete_some_nodes = deleted_nodes_ixs != []
  let must_delete_nodes_rewards = out_distribution == expected_distribution

  expect
    must_keep_other_settings_unchanged && must_not_break_multisig && must_not_add_nodes && must_delete_some_nodes && must_delete_nodes_rewards

  deleted_nodes
}

fn push_changed_node(
  node: Pair<FeedVkh, PaymentVkh>,
  acc: (Nodes, Int, List<Int>, Nodes),
) -> (Nodes, Int, List<Int>, Nodes) {
  let (out_nodes, node_ix, ixs, nodes) = acc
  when out_nodes is {
    [] -> ([], node_ix + 1, list.push(ixs, node_ix), list.push(nodes, node))
    [x, ..xs] ->
      if x == node {
        (xs, node_ix + 1, ixs, nodes)
      } else {
        (
          out_nodes,
          node_ix + 1,
          list.push(ixs, node_ix),
          list.push(nodes, node),
        )
      }
  }
}

fn push_unchanged_node_reward(
  node_ix: Int,
  node_reward: Int,
  acc: (List<Int>, List<Int>),
) -> (List<Int>, List<Int>) {
  let (deleted_nodes, result) = acc
  when deleted_nodes is {
    [] -> ([], list.push(result, node_reward))
    [x, ..xs] ->
      if x == node_ix {
        (xs, result)
      } else {
        (deleted_nodes, list.push(result, node_reward))
      }
  }
}

fn get_length_and_check_strict_order(node_ids_sorted: List<FeedVkh>) -> Int {
  when node_ids_sorted is {
    [] -> 0
    [x, ..xs] -> do_get_length_and_check_strict_order(xs, 1, x)
  }
}

fn do_get_length_and_check_strict_order(
  node_ids_sorted: List<FeedVkh>,
  n: Int,
  prev: FeedVkh,
) -> Int {
  when node_ids_sorted is {
    [] -> n
    [x, ..xs] ->
      if builtin.less_than_bytearray(prev, x) {
        do_get_length_and_check_strict_order(xs, n + 1, x)
      } else {
        fail @"E6"
      }
  }
}

pub fn check_nodes_final_rewards_paid_returning(
  oracle_conf: OracleConfiguration,
  tx_outputs: List<Output>,
  in_settings: OracleSettingsDatum,
  in_distribution: List<Int>,
  deleted_nodes: Nodes,
  current_time: PosixTime,
) -> Int {
  trace @"T31"

  let remaining_rewards =
    list.map2(
      pairs.keys(in_settings.nodes),
      in_distribution,
      fn(id, reward) { Pair(id, reward) },
    )
      |> dict.from_ascending_pairs

  when oracle_conf.fee_token is {
    None ->
      list.reduce(
        deleted_nodes,
        0,
        fn(rewards_accumulator, Pair(feed_vkh, payment_vkh)) {
          expect Some(final_reward_amount) =
            dict.get(remaining_rewards, feed_vkh)
          let node_addr = address.from_verification_key(payment_vkh)

          expect
            final_reward_amount == 0 || final_ada_rewards_paid(
              tx_outputs,
              node_addr,
              final_reward_amount,
            )

          rewards_accumulator + final_reward_amount
        },
      )
    Some(fee_asset) -> {
      let escrow_outputs =
        extract_escrow_outputs(
          tx_outputs,
          oracle_conf.reward_escrow_script_hash,
          fee_asset,
        )

      list.reduce(
        deleted_nodes,
        0,
        fn(rewards_accumulator, Pair(feed_vkh, payment_vkh)) {
          expect Some(final_reward_amount) =
            dict.get(remaining_rewards, feed_vkh)

          expect
            final_reward_amount == 0 || final_token_rewards_paid(
              escrow_outputs,
              payment_vkh,
              final_reward_amount,
              current_time,
              oracle_conf.platform_auth_nft,
              oracle_conf.reward_dismissing_period_length,
            )

          rewards_accumulator + final_reward_amount
        },
      )
    }
  }
}

fn extract_escrow_outputs(
  tx_outputs: List<Output>,
  reward_escrow_script_hash: ScriptHash,
  fee_token: Asset,
) -> List<(RewardEscrowDatum, Int)> {
  let escrow_script_addr = address.from_script(reward_escrow_script_hash)

  list.filter_map(
    tx_outputs,
    fn(out) {
      if out.address == escrow_script_addr {
        expect tx.InlineDatum(datum) = out.datum
        expect escrow_datum: RewardEscrowDatum = datum

        Some(
          (
            escrow_datum,
            assets.quantity_of(out.value, fee_token.policy_id, fee_token.name),
          ),
        )
      } else {
        None
      }
    },
  )
}

fn final_ada_rewards_paid(
  tx_outputs: List<Output>,
  node_addr: Address,
  final_reward_amount: Int,
) -> Bool {
  list.find(
    tx_outputs,
    fn(out) {
      out.address == node_addr && assets.lovelace_of(out.value) >= final_reward_amount
    },
  )
    |> option.is_some
}

fn final_token_rewards_paid(
  escrow_outputs: List<(RewardEscrowDatum, Int)>,
  node_payment_vkh: PaymentVkh,
  final_reward_amount: Int,
  current_time: PosixTime,
  platform_auth_nft: PolicyId,
  reward_dismissing_period_length: PosixTimeDiff,
) -> Bool {
  list.find(
    escrow_outputs,
    fn((escrow_datum, escrow_amount)) {
      escrow_datum.reward_issuer_nft == platform_auth_nft && escrow_datum.escrow_expiration_timestamp == current_time + reward_dismissing_period_length && escrow_datum.reward_receiver == node_payment_vkh && escrow_amount == final_reward_amount
    },
  )
    |> option.is_some
}

pub fn validate_dismissing_period(
  aggregation: Aggregation,
  tx_validity_range: ValidityRange,
  reward_dismissing_period_length: PosixTimeDiff,
) -> Bool {
  trace @"T33"

  interval.is_entirely_after(
    tx_validity_range,
    aggregation.message.timestamp + reward_dismissing_period_length,
  )
}
