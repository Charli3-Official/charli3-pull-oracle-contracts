use aiken/builtin
use aiken/collection/dict
use aiken/collection/list
use aiken/collection/pairs
use aiken/crypto.{ScriptHash}
use aiken/interval
use aiken/math/rational
use aiken/option.{is_some}
use cardano/assets.{PolicyId, Value}
use cardano/transaction.{Input, Output, ValidityRange} as tx
use ext/aiken/collection/list.{indexed_zip_with} as list_ext
use ext/aiken/math/rational.{Percent, coin_precision} as ext
use ext/cardano/value.{Asset}
use oracle/consensus.{consensus_by_iqr}
use oracle/datum.{
  AggState, AggStateDatum, AggregateMessage, Node, NodeFeed, OracleDatum,
  OracleFeed, RewardConsensusPending, RewardDatum, RewardPrices, RewardTransport,
  RewardTransportDatum, has_no_rewards,
}
use services/protocol_token.{
  find_script_inputs_by_token, find_script_outputs_by_token,
}

pub type AnAggregation {
  median: OracleFeed,
  message: AggregateMessage,
  value: Value,
}

pub fn spends_reward_acc_utxo(
  script_hash: ScriptHash,
  reward_acc_nft: Asset,
  tx_inputs: List<Input>,
) -> Bool {
  trace @"spends_reward_acc_utxo"

  let inputs =
    find_script_inputs_by_token(tx_inputs, script_hash, reward_acc_nft)

  list.length(inputs) == 1
}

pub fn returns_empty_reward_outputs(
  script_hash: ScriptHash,
  reward_transport_nft: Asset,
  allowed_asset: PolicyId,
  utxo_count: Int,
  tx_outputs: List<Output>,
) -> Bool {
  trace @"returns_empty_reward_outputs"

  let outputs =
    find_script_outputs_by_token(
      tx_outputs,
      script_hash,
      allowed_asset,
      reward_transport_nft,
    )
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
  allowed_asset: PolicyId,
  utxo_count: Int,
  tx_outputs: List<Output>,
) -> Bool {
  trace @"returns_empty_aggstate_outputs"

  let outputs =
    find_script_outputs_by_token(
      tx_outputs,
      script_hash,
      allowed_asset,
      aggstate_nft,
    )
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
  allowed_asset: PolicyId,
) -> (OracleDatum, Value) {
  trace @"find_out_datum_and_value"

  expect [script_out] =
    find_script_outputs_by_token(
      tx_outputs,
      script_hash,
      allowed_asset,
      protocol_token,
    )
  expect tx.InlineDatum(datum) = script_out.datum
  expect oracle_datum: OracleDatum = datum

  (oracle_datum, script_out.value)
}

pub fn find_in_datum(
  tx_inputs: List<Input>,
  script_hash: ScriptHash,
  protocol_token: Asset,
) -> OracleDatum {
  trace @"find_in_datum"

  expect [script_in] =
    find_script_inputs_by_token(tx_inputs, script_hash, protocol_token)
  expect tx.InlineDatum(datum) = script_in.output.datum
  expect oracle_datum: OracleDatum = datum

  oracle_datum
}

pub fn find_in_aggregations(
  tx_inputs: List<Input>,
  script_hash: ScriptHash,
  protocol_token: Asset,
) -> List<AnAggregation> {
  trace @"find_in_aggregations"

  let inputs =
    find_script_inputs_by_token(tx_inputs, script_hash, protocol_token)
  let extractor =
    fn(input: Input) -> AnAggregation {
      expect tx.InlineDatum(datum) = input.output.datum
      expect oracle_datum: OracleDatum = datum
      expect RewardTransport(RewardConsensusPending { oracle_feed, message }) =
        oracle_datum

      AnAggregation { value: input.output.value, median: oracle_feed, message }
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

pub fn are_mutable_settings_unchanged(
  in_core_datum: RewardDatum,
  out_core_datum: RewardDatum,
) -> Bool {
  trace @"are_mutable_settings_unchanged"

  in_core_datum.fee_info == out_core_datum.fee_info && in_core_datum.iqr_fence_multiplier == out_core_datum.iqr_fence_multiplier && in_core_datum.aggregation_liveness_period == out_core_datum.aggregation_liveness_period && in_core_datum.time_absolute_uncertainty == out_core_datum.time_absolute_uncertainty && in_core_datum.closing_period_started_at == out_core_datum.closing_period_started_at && pairs.keys(
    in_core_datum.nodes_to_rewards,
  ) == pairs.keys(out_core_datum.nodes_to_rewards)
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
  in_distribution: Pairs<Node, Int>,
  out_distribution: Pairs<Node, Int>,
  reward_prices: RewardPrices,
  iqr_fence_multiplier: Percent,
) -> Bool {
  trace @"check_reward_distribution"

  let node_id_to_reward =
    indexed_zip_with(
      out_distribution,
      in_distribution,
      fn(index, out, in) {
        (index, builtin.snd_pair(out) - builtin.snd_pair(in))
      },
    )

  let beneficiaries =
    list.flat_map(
      aggregations,
      fn(a) {
        consensus_by_iqr(
          a.message.node_feeds_sorted_by_feed,
          a.message.node_feeds_count,
          iqr_fence_multiplier,
        )
      },
    )

  let check_node =
    fn((index, actual_reward)) -> Bool {
      let reward_count =
        beneficiaries |> list.filter(fn(b) { index == b }) |> list.length
      let required_reward = reward_count * reward_prices.node_fee

      required_reward == actual_reward
    }

  list.all(node_id_to_reward, check_node)
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
