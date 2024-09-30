use aiken/collection/dict
use aiken/collection/list
use aiken/crypto.{ScriptHash}
use aiken/option.{is_some}
use cardano/assets.{PolicyId, Value}
use cardano/transaction.{Input, Output} as tx
use ext/aiken/time.{PosixTime}
use ext/cardano/value.{Asset}
use oracle/datum.{
  AggState, AggStateDatum, AggregateMessage, OracleDatum, OracleFeed,
  RewardConsensusPending, RewardTransport, RewardTransportDatum, has_no_rewards,
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
      expect RewardTransport(RewardConsensusPending { median, message }) =
        oracle_datum

      AnAggregation { value: input.output.value, median, message }
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
  current_time: PosixTime,
) -> Bool {
  trace @"is_aggstate_expired"

  aggstate
    |> option.map(fn(state) { state.expiry_timestamp < current_time })
    |> option.or_else(True)
}
