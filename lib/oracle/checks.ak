use aiken/builtin
use aiken/collection/dict
use aiken/collection/list
use aiken/collection/pairs
use aiken/crypto.{ScriptHash, VerificationKeyHash}
use aiken/interval
use aiken/math/rational
use aiken/option.{is_some}
use cardano/assets.{PolicyId, Value}
use cardano/transaction.{Input,
  Output, Redeemer, ScriptPurpose, ValidityRange} as tx
use ext/aiken/math/rational.{Percent, Permille, coin_precision} as ext
use ext/aiken/time.{PosixTime, PosixTimeDiff}
use ext/cardano/value.{Asset}
use oracle/consensus.{consensus_by_iqr_and_divergency}
use oracle/datum.{
  AggState, AggregateMessage, FeedVkh, GenericData, NodeFeed, Nodes,
  OracleConfiguration, OracleDatum, OracleFeed, OracleSettingsDatum, PaymentVkh,
  PriceData, RewardAccount, RewardAccountDatum, RewardPrices, get_price_data,
}
use oracle/redeemer.{AddNodes, OdvAggregate, OracleRedeemer}
use services/protocol_token.{
  find_script_inputs_by_token, find_script_outputs_by_token,
  find_script_outputs_by_token_allowing_asset,
}

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
  total_input_accounts: Int,
  tx_outputs: List<Output>,
  utxo_size_safety_buffer: Int,
) -> Bool {
  trace @"T9"

  let outputs =
    find_script_outputs_by_token(tx_outputs, script_hash, reward_account_nft)
  let extractor =
    fn(output: Output) -> Value {
      expect tx.InlineDatum(datum) = output.datum
      expect oracle_datum: OracleDatum = datum
      expect RewardAccount(RewardAccountDatum { nodes_to_rewards: [], .. }) =
        oracle_datum

      output.value
    }
  let empty_outputs_value = list.map(outputs, extractor)

  list.length(empty_outputs_value) == total_input_accounts && list.all(
    empty_outputs_value,
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
) -> List<(OracleDatum, Value)> {
  trace @"T11"

  let script_outputs =
    find_script_outputs_by_token(tx_outputs, script_hash, protocol_token)
  list.map(
    script_outputs,
    fn(script_output) {
      expect tx.InlineDatum(datum) = script_output.datum
      expect oracle_datum: OracleDatum = datum
      (oracle_datum, script_output.value)
    },
  )
}

pub fn find_out_datum_and_value_with_allowing_asset(
  tx_outputs: List<Output>,
  script_hash: ScriptHash,
  protocol_token: Asset,
  allowed_asset: Option<Asset>,
) -> List<(OracleDatum, Value)> {
  trace @"T12"

  when allowed_asset is {
    None -> find_out_datum_and_value(tx_outputs, script_hash, protocol_token)
    Some(asset) -> {
      let script_outputs =
        find_script_outputs_by_token_allowing_asset(
          tx_outputs,
          script_hash,
          asset.policy_id,
          protocol_token,
        )
      list.map(
        script_outputs,
        fn(script_output) {
          expect tx.InlineDatum(datum) = script_output.datum
          expect oracle_datum: OracleDatum = datum
          (oracle_datum, script_output.value)
        },
      )
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

pub fn find_in_reward_accounts(
  tx_inputs: List<Input>,
  tx_redeemers: Pairs<ScriptPurpose, Redeemer>,
  script_hash: ScriptHash,
  protocol_token: Asset,
  redeemer: OracleRedeemer,
) -> Int {
  trace @"T15"

  let inputs =
    find_script_inputs_by_token(tx_inputs, script_hash, protocol_token)

  let as_data: Data = redeemer
  let refs = list.map(inputs, fn(i) { i.output_reference })
  let must_have_correct_redeemers =
    list.all(
      refs,
      fn(ref) {
        expect Some(r) = pairs.get_first(tx_redeemers, tx.Spend(ref))
        r == as_data
      },
    )
  expect must_have_correct_redeemers
  let extractor =
    fn(input: Input, acc: List<RewardAccountDatum>) -> List<RewardAccountDatum> {
      expect tx.InlineDatum(datum) = input.output.datum
      expect oracle_datum: OracleDatum = datum
      expect RewardAccount(reward_account_datum) = oracle_datum
      // Check if this datum is already in the accumulator
      let exists =
        list.any(
          acc,
          fn(existing_datum) { existing_datum == reward_account_datum },
        )
      if exists {
        // Skip duplicates
        acc
      } else {
        // Add unique datum to accumulator
        [reward_account_datum, ..acc]
      }
    }
  // Get unique reward accounts
  let unique_accounts = list.foldr(inputs, [], extractor)
  // Return the count of unique accounts
  list.length(unique_accounts)
}

pub fn find_out_reward_accounts(
  tx_outputs: List<Output>,
  script_hash: ScriptHash,
  protocol_token: Asset,
) -> Int {
  trace @"T15"

  let outputs =
    find_script_outputs_by_token(tx_outputs, script_hash, protocol_token)

  let extractor =
    fn(output: Output, acc: Int) -> Int {
      expect tx.InlineDatum(datum) = output.datum
      expect oracle_datum: OracleDatum = datum
      expect RewardAccount(RewardAccountDatum { .. }) = oracle_datum
      acc + 1
    }
  list.foldr(outputs, 0, extractor)
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

pub fn check_reward_distribution(
  message: AggregateMessage,
  median: OracleFeed,
  node_reward_price: Int,
  in_distribution: Pairs<FeedVkh, Int>,
  out_distribution: Pairs<FeedVkh, Int>,
  nodes: Nodes,
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
  // Create a set of rewarded feed VKHs - using a map for O(n) lookups
  let rewarded_feed_dict =
    list.foldr(
      rewarded_feed_nodes,
      dict.empty,
      fn(feed_vkh, acc) { dict.insert(acc, feed_vkh, True) },
    )
  // Process all records in a single pass to avoid creating of intermediate data structures
  list.all(
    out_distribution,
    fn(Pair(out_feed_vkh, out_amount)) {
      let allowed_feed_vkh =
        dict.from_ascending_pairs(nodes)
          |> dict.has_key(out_feed_vkh)
      if !allowed_feed_vkh {
        // Invalid payment VKH - not in the nodes list
        False
      } else {
        // Determine expected reward based on whether this feed node was rewarded
        let expected_reward =
          if dict.has_key(rewarded_feed_dict, out_feed_vkh) {
            node_reward_price
          } else {
            0
          }
        // Get input amount, defaulting to 0 if not present
        let in_amount =
          dict.from_ascending_pairs(in_distribution)
            |> dict.get(out_feed_vkh)
            |> option.or_else(0)
        // 0 since it's a new node
        // Check if the output amount matches expected
        in_amount + expected_reward == out_amount
      }
    },
  )
}

pub fn validate_message_form(message: AggregateMessage) -> Bool {
  trace @"T21"
  go_check_order_and_count(
    pairs.values(message.node_feeds_sorted_by_feed),
    0,
    None,
  ) == message.node_feeds_count
}

fn go_check_order_and_count(
  node_feeds: List<NodeFeed>,
  count: Int,
  prev_opt: Option<NodeFeed>,
) -> Int {
  when node_feeds is {
    [] -> count
    [curr, ..rest] ->
      // Check ordering only if we have a previous value
      when prev_opt is {
        Some(prev) ->
          if prev <= curr {
            go_check_order_and_count(rest, count + 1, Some(curr))
          } else {
            fail @"E5"
          }
        None -> go_check_order_and_count(rest, count + 1, Some(curr))
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
) -> Option<FeedVkh> {
  trace @"T25"

  let maybe_node =
    list.find(
      nodes,
      fn(Pair(_, payment_vkh)) { list.has(tx_signatories, payment_vkh) },
    )

  maybe_node |> option.map(fn(Pair(feed_vkh, _)) { feed_vkh })
}

pub fn check_node_received_reward(
  fee_token: Option<Asset>,
  maybe_feed_vkh: Option<FeedVkh>,
  in_distribution: RewardAccountDatum,
  in_value: Value,
  reward_output_accounts: List<(OracleDatum, Value)>,
) -> Bool {
  trace @"T26"
  // Check if the feed VKH exists
  when maybe_feed_vkh is {
    None -> False
    Some(feed_vkh) -> {
      // Find the reward amount directly in input distribution
      let in_distribution_dict =
        dict.from_ascending_pairs(in_distribution.nodes_to_rewards)
      when dict.get(in_distribution_dict, feed_vkh) is {
        None -> False
        Some(required_reward) ->
          if required_reward <= 0 {
            False
          } else {
            // Find the matching output account
            list.any(
              reward_output_accounts,
              fn(reward_output_account) {
                expect (
                  RewardAccount(RewardAccountDatum {
                    nodes_to_rewards,
                    last_update_time,
                  }),
                  out_value,
                ) = reward_output_account
                let out_distribution_dict =
                  dict.from_ascending_pairs(nodes_to_rewards)
                // Ensure that feed_vkh does NOT exist in out_distribution.
                // The node must withdraw all rewards and remove it from the out_distribution.
                if dict.has_key(out_distribution_dict, feed_vkh) {
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
                  // Remove the rewarded node from the input and compare the resulting lists.
                  // Ensure the required reward matches the actual reward.
                  // The last time update must remain unchanged during this transaction.
                  dict.delete(in_distribution_dict, feed_vkh) == out_distribution_dict && required_reward == actual_reward && last_update_time == in_distribution.last_update_time
                }
              },
            )
          }
      }
    }
  }
}

pub fn check_platform_received_reward(
  fee_token: Option<Asset>,
  utxo_size_safety_buffer: Int,
  in_account_datum: RewardAccountDatum,
  in_value: Value,
  reward_output_accounts: List<(OracleDatum, Value)>,
) -> Bool {
  trace @"T27"

  // Calculate total rewards to be distributed to nodes
  let nodes_rewards =
    list.foldr(
      in_account_datum.nodes_to_rewards,
      0,
      fn(Pair(_, reward), total) { reward + total },
    )

  let in_total_rewards =
    calculate_asset_quantity_with_default(in_value, fee_token)

  // The output rewards should be in the reward output accounts
  // Find output with matching datum (no changes allowed)
  expect Some((_, out_value)) =
    list.find(
      reward_output_accounts,
      fn(output_account) {
        let (oracle_datum, _) = output_account
        expect RewardAccount(RewardAccountDatum {
          nodes_to_rewards,
          last_update_time,
        }) = oracle_datum
        // Verify datum hasn't changed
        nodes_to_rewards == in_account_datum.nodes_to_rewards && last_update_time == in_account_datum.last_update_time
      },
    )

  let out_total_rewards =
    calculate_asset_quantity_with_default(out_value, fee_token)

  let actual_reward = in_total_rewards - out_total_rewards

  // Check safety buffer requirements
  let must_save_nodes_rewards =
    when fee_token is {
      Some(_) ->
        out_total_rewards >= nodes_rewards && check_utxo_size_safety_buffer(
          utxo_size_safety_buffer,
          out_value,
        )
      None -> out_total_rewards >= nodes_rewards + utxo_size_safety_buffer
    }

  must_save_nodes_rewards && actual_reward > 0
}

fn push_deleted_node(
  node: Pair<FeedVkh, PaymentVkh>,
  acc: (Nodes, Nodes),
) -> (Nodes, Nodes) {
  let (result, out_nodes) = acc
  when out_nodes is {
    [] -> (list.push(result, node), [])
    [x, ..xs] ->
      if x == node {
        (result, xs)
      } else {
        (list.push(result, node), out_nodes)
      }
  }
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

pub fn check_nodes_update(
  in_settings: OracleSettingsDatum,
  out_settings: OracleSettingsDatum,
  redeemer: OracleRedeemer,
) -> Bool {
  trace @"T28"

  let (deleted_nodes, added_nodes) =
    when redeemer is {
      AddNodes ->
        list.foldl(out_settings.nodes, (in_settings.nodes, []), push_added_node)
      _ ->
        list.foldl(
          in_settings.nodes,
          ([], out_settings.nodes),
          push_deleted_node,
        )
    }

  let must_keep_other_settings_unchanged =
    in_settings.fee_info == out_settings.fee_info && in_settings.aggregation_liveness_period == out_settings.aggregation_liveness_period && in_settings.time_uncertainty_platform == out_settings.time_uncertainty_platform && in_settings.time_uncertainty_aggregation == out_settings.time_uncertainty_aggregation && in_settings.iqr_fence_multiplier == out_settings.iqr_fence_multiplier && in_settings.median_divergency_factor == out_settings.median_divergency_factor && in_settings.utxo_size_safety_buffer == out_settings.utxo_size_safety_buffer && in_settings.pause_period_started_at == out_settings.pause_period_started_at

  let must_not_break_multisig =
    out_settings.required_node_signatures_count > 0 && out_settings.required_node_signatures_count <= get_length_and_check_strict_order(
      pairs.keys(out_settings.nodes),
    )

  when redeemer is {
    AddNodes ->
      must_keep_other_settings_unchanged && must_not_break_multisig && deleted_nodes == [] && added_nodes != []
    _ ->
      must_keep_other_settings_unchanged && must_not_break_multisig && deleted_nodes != [] && added_nodes == []
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

pub fn validate_dismissing_period(
  last_update_time: PosixTime,
  tx_validity_range: ValidityRange,
  reward_dismissing_period_length: PosixTimeDiff,
) -> Bool {
  trace @"T33"

  interval.is_entirely_after(
    tx_validity_range,
    last_update_time + reward_dismissing_period_length,
  )
}
