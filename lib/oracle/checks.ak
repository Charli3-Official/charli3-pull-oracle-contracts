use aiken/builtin
use aiken/collection/dict.{Dict}
use aiken/collection/list
use aiken/collection/pairs
use aiken/crypto.{ScriptHash, VerificationKeyHash}
use aiken/interval
use aiken/math/rational
use aiken/option.{is_some}
use cardano/assets.{PolicyId, Value}
use cardano/transaction.{Input,
  Output, Redeemer, ScriptPurpose, ValidityRange} as tx
use ext/aiken/math/rational.{Percent, coin_precision} as ext
use ext/cardano/value.{Asset}
use oracle/consensus.{consensus_by_iqr}
use oracle/datum.{
  AggState, AggStateDatum, AggregateMessage, FeedVkh, NodeFeed, Nodes,
  OracleDatum, OracleFeed, OracleSettingsDatum, PaymentVkh,
  RewardConsensusPending, RewardPrices, RewardTransport, RewardTransportDatum,
  has_no_rewards,
}
use oracle/redeemer.{CalculateRewards, OracleRedeemer}
use services/protocol_token.{
  find_script_inputs_by_token, find_script_outputs_by_token,
  find_script_outputs_by_token_allowing_asset,
}

pub type AnAggregation {
  median: OracleFeed,
  message: AggregateMessage,
  node_reward_price: Int,
  value: Value,
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
  let as_data: Data = redeemer
  expect [input] = find_script_inputs_by_token(tx_inputs, script_hash, nft)
  expect Some(r) =
    pairs.get_first(tx_redeemers, tx.Spend(input.output_reference))

  r == as_data
}

pub fn returns_empty_reward_outputs(
  script_hash: ScriptHash,
  reward_transport_nft: Asset,
  utxo_count: Int,
  tx_outputs: List<Output>,
) -> Bool {
  trace @"returns_empty_reward_outputs"

  let outputs =
    find_script_outputs_by_token(tx_outputs, script_hash, reward_transport_nft)
  let extractor =
    fn(output: Output) -> RewardTransportDatum {
      expect tx.InlineDatum(datum) = output.datum
      expect oracle_datum: OracleDatum = datum
      expect RewardTransport(reward_transport) = oracle_datum

      reward_transport
    }
  let datums = list.map(outputs, extractor)

  list.length(outputs) == utxo_count && list.all(datums, has_no_rewards)
}

pub fn returns_empty_aggstate_outputs(
  script_hash: ScriptHash,
  aggstate_nft: Asset,
  utxo_count: Int,
  tx_outputs: List<Output>,
) -> Bool {
  trace @"returns_empty_aggstate_outputs"

  let outputs =
    find_script_outputs_by_token(tx_outputs, script_hash, aggstate_nft)
  let extractor =
    fn(output: Output) -> Option<AggStateDatum> {
      expect tx.InlineDatum(datum) = output.datum
      expect oracle_datum: OracleDatum = datum
      expect AggState(aggstate) = oracle_datum

      aggstate
    }
  let datums = list.map(outputs, extractor)

  list.length(outputs) == utxo_count && list.all(datums, option.is_none)
}

pub fn find_out_datum_and_value(
  tx_outputs: List<Output>,
  script_hash: ScriptHash,
  protocol_token: Asset,
) -> (OracleDatum, Value) {
  trace @"find_out_datum_and_value"

  expect [script_out] =
    find_script_outputs_by_token(tx_outputs, script_hash, protocol_token)
  expect tx.InlineDatum(datum) = script_out.datum
  expect oracle_datum: OracleDatum = datum

  (oracle_datum, script_out.value)
}

pub fn find_out_datum_and_value_allowing_asset(
  tx_outputs: List<Output>,
  script_hash: ScriptHash,
  protocol_token: Asset,
  allowed_asset: PolicyId,
) -> (OracleDatum, Value) {
  trace @"find_out_datum_and_value_allowing_asset"

  expect [script_out] =
    find_script_outputs_by_token_allowing_asset(
      tx_outputs,
      script_hash,
      allowed_asset,
      protocol_token,
    )
  expect tx.InlineDatum(datum) = script_out.datum
  expect oracle_datum: OracleDatum = datum

  (oracle_datum, script_out.value)
}

pub fn find_referenced_datum(
  tx_reference_inputs: List<Input>,
  script_hash: ScriptHash,
  protocol_token: Asset,
) -> OracleDatum {
  trace @"find_referenced_datum"

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
  trace @"find_in_datum"

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

pub fn find_in_aggregations(
  tx_inputs: List<Input>,
  tx_redeemers: Pairs<ScriptPurpose, Redeemer>,
  script_hash: ScriptHash,
  protocol_token: Asset,
) -> List<AnAggregation> {
  trace @"find_in_aggregations"

  let inputs =
    find_script_inputs_by_token(tx_inputs, script_hash, protocol_token)

  let as_data: Data = CalculateRewards
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
    fn(input: Input) -> AnAggregation {
      expect tx.InlineDatum(datum) = input.output.datum
      expect oracle_datum: OracleDatum = datum
      expect RewardTransport(RewardConsensusPending {
        oracle_feed,
        message,
        node_reward_price,
      }) = oracle_datum

      AnAggregation {
        value: input.output.value,
        median: oracle_feed,
        message,
        node_reward_price,
      }
    }

  list.map(inputs, extractor)
}

pub fn does_not_produce_own_nft_outputs(
  tx_outputs: List<Output>,
  own_nft_policy_id: PolicyId,
) -> Bool {
  trace @"does_not_produce_own_nft_outputs"
  tx_outputs
    |> list.filter(
        fn(o) {
          o.value |> assets.to_dict |> dict.get(own_nft_policy_id) |> is_some
        },
      )
    |> list.is_empty
}

pub fn is_aggstate_expired(
  aggstate: Option<AggStateDatum>,
  tx_validity_range: ValidityRange,
) -> Bool {
  trace @"is_aggstate_expired"

  aggstate
    |> option.map(
        fn(state) {
          interval.is_entirely_after(tx_validity_range, state.expiry_timestamp)
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
      expect AggState(Some(rate_datum)) = oracle_datum
      expect Some(rate) = rational.new(rate_datum.oracle_feed, coin_precision)

      expect
        interval.is_entirely_before(
          tx_validity_range,
          rate_datum.expiry_timestamp,
        )

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

pub fn calculate_minimum_fee_amout(
  reward_prices: RewardPrices,
  nodes_count: Int,
) -> Int {
  reward_prices.node_fee * nodes_count + reward_prices.platform_fee
}

pub fn oracle_fees_were_transfered(
  fee_token: Asset,
  aggregations: List<AnAggregation>,
  in_value: Value,
  out_value: Value,
) -> Bool {
  trace @"oracle_fees_were_transfered"

  let actual_fee =
    assets.quantity_of(out_value, fee_token.policy_id, fee_token.name) - assets.quantity_of(
      in_value,
      fee_token.policy_id,
      fee_token.name,
    )
  let required_fee =
    list.foldr(
      aggregations,
      0,
      fn(aggregation, acc) {
        acc + assets.quantity_of(
          aggregation.value,
          fee_token.policy_id,
          fee_token.name,
        )
      },
    )

  actual_fee == required_fee
}

pub fn check_reward_distribution(
  aggregations: List<AnAggregation>,
  in_distribution: List<Int>,
  out_distribution: List<Int>,
  nodes: Nodes,
  iqr_fence_multiplier: Percent,
) -> Bool {
  trace @"check_reward_distribution"

  let node_ids = pairs.keys(nodes)

  let check_nodes_count =
    list.length(in_distribution) == list.length(out_distribution)

  let actual_rewards =
    list.map2(out_distribution, in_distribution, fn(out, in) { out - in })

  let sum_rewards =
    fn(_k, a, b) { Some(a + b) }
  let required_rewards =
    list.foldr(
      aggregations,
      list.map(node_ids, fn(id) { Pair(id, 0) })
        |> dict.from_ascending_pairs,
      fn(aggregation, acc) {
        let rewarded_nodes =
          consensus_by_iqr(
            aggregation.message.node_feeds_sorted_by_feed,
            aggregation.message.node_feeds_count,
            iqr_fence_multiplier,
          )
        list.foldr(
          rewarded_nodes,
          acc,
          fn(node_id, d) {
            dict.insert_with(
              d,
              node_id,
              aggregation.node_reward_price,
              sum_rewards,
            )
          },
        )
      },
    )

  let check_same_nodes = dict.keys(required_rewards) == node_ids
  let check_rewards_paid = dict.values(required_rewards) == actual_rewards

  check_nodes_count? && check_same_nodes? && check_rewards_paid?
}

pub fn validate_message_form(message: AggregateMessage) -> Bool {
  trace @"validate_message_form"

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
        fail @"check node feeds order"
      }
  }
}

pub fn check_settings_sanity(
  in_settings: OracleSettingsDatum,
  out_settings: OracleSettingsDatum,
) -> Bool {
  trace @"check_settings_sanity"

  let must_not_break_multisig =
    out_settings.required_node_signatures_count > 0 && out_settings.required_node_signatures_count <= list.length(
      out_settings.nodes,
    )
  let must_measure_time_precisely =
    out_settings.aggregation_liveness_period > out_settings.time_absolute_uncertainty
  let must_have_positive_intervals = out_settings.time_absolute_uncertainty > 0
  let must_be_fair_about_outliers = out_settings.iqr_fence_multiplier > 100

  in_settings.nodes == out_settings.nodes && in_settings.fee_info == out_settings.fee_info && in_settings.closing_period_started_at == out_settings.closing_period_started_at && must_not_break_multisig && must_measure_time_precisely && must_have_positive_intervals && must_be_fair_about_outliers
}

pub fn check_fee_settings_sanity(
  in_settings: OracleSettingsDatum,
  out_settings: OracleSettingsDatum,
) -> Bool {
  trace @"check_fee_settings_sanity"

  let must_not_have_negative_price =
    out_settings.fee_info.reward_prices.node_fee >= 0 && out_settings.fee_info.reward_prices.platform_fee >= 0

  in_settings.nodes == out_settings.nodes && in_settings.required_node_signatures_count == out_settings.required_node_signatures_count && in_settings.aggregation_liveness_period == out_settings.aggregation_liveness_period && in_settings.time_absolute_uncertainty == out_settings.time_absolute_uncertainty && in_settings.iqr_fence_multiplier == out_settings.iqr_fence_multiplier && in_settings.closing_period_started_at == out_settings.closing_period_started_at && must_not_have_negative_price
}

pub fn check_closing_does_not_change_settings(
  in_core_datum: OracleSettingsDatum,
  out_core_datum: OracleSettingsDatum,
) -> Bool {
  trace @"check_closing_does_not_change_settings"

  in_core_datum.nodes == out_core_datum.nodes && in_core_datum.iqr_fence_multiplier == out_core_datum.iqr_fence_multiplier && in_core_datum.fee_info == out_core_datum.fee_info && in_core_datum.aggregation_liveness_period == out_core_datum.aggregation_liveness_period && in_core_datum.time_absolute_uncertainty == out_core_datum.time_absolute_uncertainty
}

pub fn find_node_index_by_signature(
  tx_signatories: List<VerificationKeyHash>,
  nodes: Nodes,
) -> Int {
  trace @"find_node_index_by_signature"

  expect [(node_ix, _)] =
    list.indexed_map(nodes, fn(index, node) { (index, builtin.snd_pair(node)) })
      |> list.filter(
          fn((_, payment_vkh)) { list.has(tx_signatories, payment_vkh) },
        )

  node_ix
}

pub fn check_node_received_reward(
  fee_token: Asset,
  rewarded_node_index: Int,
  in_distribution: List<Int>,
  out_distribution: List<Int>,
  in_value: Value,
  out_value: Value,
) -> Bool {
  trace @"check_node_received_reward"

  expect (in_init, [in_reward, ..in_tail]) =
    list.span(in_distribution, rewarded_node_index)
  expect (out_init, [out_reward, ..out_tail]) =
    list.span(out_distribution, rewarded_node_index)
  let required_reward = in_reward - out_reward

  let actual_reward =
    assets.quantity_of(in_value, fee_token.policy_id, fee_token.name) - assets.quantity_of(
      out_value,
      fee_token.policy_id,
      fee_token.name,
    )

  let must_not_modify_other_nodes = in_init == out_init && in_tail == out_tail
  let must_withdraw_reward = required_reward > 0
  let must_receive_reward = required_reward == actual_reward

  must_not_modify_other_nodes && must_withdraw_reward && must_receive_reward
}

pub fn check_platform_received_reward(
  fee_token: Asset,
  reward_distribution: List<Int>,
  in_value: Value,
  out_value: Value,
) -> Bool {
  trace @"check_platform_received_reward"

  let nodes_rewards =
    list.foldr(reward_distribution, 0, fn(reward, total) { reward + total })

  let in_total_rewards =
    assets.quantity_of(in_value, fee_token.policy_id, fee_token.name)
  let out_total_rewards =
    assets.quantity_of(out_value, fee_token.policy_id, fee_token.name)
  let actual_reward = in_total_rewards - out_total_rewards

  let must_save_nodes_rewards = out_total_rewards >= nodes_rewards
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
  trace @"check_added_nodes"

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
    in_settings.fee_info == out_settings.fee_info && in_settings.aggregation_liveness_period == out_settings.aggregation_liveness_period && in_settings.time_absolute_uncertainty == out_settings.time_absolute_uncertainty && in_settings.iqr_fence_multiplier == out_settings.iqr_fence_multiplier && in_settings.closing_period_started_at == out_settings.closing_period_started_at
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
pub fn check_deleted_nodes(
  in_settings: OracleSettingsDatum,
  out_settings: OracleSettingsDatum,
  in_distribution: List<Int>,
  out_distribution: List<Int>,
) -> Bool {
  trace @"check_deleted_nodes"

  let (added_nodes, _, deleted_nodes) =
    list.foldl(
      in_settings.nodes,
      (out_settings.nodes, 0, []),
      push_changed_node,
    )
  let (_, expected_distribution) =
    list.indexed_foldr(
      in_distribution,
      (deleted_nodes, []),
      push_unchanged_node_reward,
    )

  let must_keep_other_settings_unchanged =
    in_settings.fee_info == out_settings.fee_info && in_settings.aggregation_liveness_period == out_settings.aggregation_liveness_period && in_settings.time_absolute_uncertainty == out_settings.time_absolute_uncertainty && in_settings.iqr_fence_multiplier == out_settings.iqr_fence_multiplier && in_settings.closing_period_started_at == out_settings.closing_period_started_at
  let must_not_break_multisig =
    out_settings.required_node_signatures_count > 0 && out_settings.required_node_signatures_count <= get_length_and_check_strict_order(
      pairs.keys(out_settings.nodes),
    )
  let must_not_add_nodes = added_nodes == []
  let must_delete_some_nodes = deleted_nodes != []
  let must_delete_nodes_rewards = out_distribution == expected_distribution

  must_keep_other_settings_unchanged && must_not_break_multisig && must_not_add_nodes && must_delete_some_nodes && must_delete_nodes_rewards
}

fn push_changed_node(
  node: Pair<FeedVkh, PaymentVkh>,
  acc: (Nodes, Int, List<Int>),
) -> (Nodes, Int, List<Int>) {
  let (out_nodes, node_ix, result) = acc
  when out_nodes is {
    [] -> ([], node_ix + 1, list.push(result, node_ix))
    [x, ..xs] ->
      if x == node {
        (xs, node_ix + 1, result)
      } else {
        (out_nodes, node_ix + 1, list.push(result, node_ix))
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
        fail @"check node ids order"
      }
  }
}
