use aiken/list
use aiken/transaction.{Input, Output, find_script_outputs}
use aiken/transaction/credential
use aiken/transaction/value.{AssetName, PolicyId, Value}
use ext/aiken/transaction/credential.{ScriptHash} as extc
use ext/aiken/transaction/value.{Asset} as extv

/// Find own protocol NFT inside the value we are spending.
/// Note that it's not required to check_own_protocol_token in tx inputs
/// because it's already been checked for each output.
pub fn find_own_protocol_policy_id(
  input_value: Value,
  nft_name: AssetName,
) -> PolicyId {
  trace @"find_own_protocol_policy_id"

  expect [(policy_id, _name, 1)] =
    input_value
      |> value.flatten
      |> list.filter(
          fn(t) {
            let (_, name, _) = t
            nft_name == name
          },
        )

  policy_id
}

/// Find own protocol NFT inside transaction inputs.
/// Note that it's not required to check_own_protocol_token in tx inputs
/// because it's already been checked for each output.
pub fn find_script_inputs_by_token(
  tx_inputs: List<Input>,
  script_hash: ScriptHash,
  protocol_token: Asset,
) -> List<Input> {
  let has_nft =
    fn(value: Value) -> Bool {
      value
        |> value.flatten
        |> list.has((protocol_token.policy_id, protocol_token.name, 1))
    }

  list.filter(
    tx_inputs,
    fn(i) {
      i.output.address == credential.from_script(script_hash) && has_nft(
        i.output.value,
      )
    },
  )
}

/// A convenience function that calls find_script_inputs_by_token
/// and also checks number of spent inputs
pub fn spends_protocol_nft_inputs(
  script_hash: ScriptHash,
  protocol_nft: Asset,
  utxo_count: Int,
  tx_inputs: List<Input>,
) -> Bool {
  let inputs = find_script_inputs_by_token(tx_inputs, script_hash, protocol_nft)

  list.length(inputs) == utxo_count
}

/// Find own protocol NFT inside transaction outputs
pub fn find_script_outputs_by_token(
  tx_outputs: List<Output>,
  script_hash: ScriptHash,
  allowed_asset: PolicyId,
  protocol_token: Asset,
) -> List<Output> {
  find_script_outputs(tx_outputs, script_hash)
    |> list.filter(
        fn(o) {
          check_own_protocol_token(o.value, allowed_asset, protocol_token)
        },
      )
}

/// Returns true if protocol NFT was found and it's the only asset except lovelace and one allowed
pub fn check_own_protocol_token(
  output_value: Value,
  allowed_asset: PolicyId,
  protocol_token: Asset,
) -> Bool {
  trace @"check_own_protocol_token"

  let tokens =
    output_value
      |> value.without_lovelace
      |> value.flatten_with(skip_allowed_asset(_, _, _, allowed_asset))

  tokens == [(protocol_token.policy_id, protocol_token.name, 1)]
}

/// Skips allowed token: e.g. C3 fee payment token
pub fn skip_allowed_asset(
  policy_id: PolicyId,
  name: AssetName,
  amount: Int,
  allowed_asset: PolicyId,
) -> Option<(PolicyId, AssetName, Int)> {
  if policy_id == allowed_asset {
    None
  } else {
    Some((policy_id, name, amount))
  }
}
