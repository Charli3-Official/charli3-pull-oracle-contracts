use aiken/collection/dict
use aiken/crypto.{ScriptHash}
use cardano/address
use cardano/assets as assets
use cardano/transaction.{Input, Output, OutputReference, Transaction}
use cardano/transaction as tx
use config
use core/checks.{
  find_out_datum_and_value, returns_empty_account_outputs,
  returns_empty_aggstate_outputs, validate_settings_form,
}
use core/datum.{
  AggState, FeeConfig, FeedVkh, GenericData, NftsConfiguration,
  OracleConfiguration, OracleSettings, OracleSettingsDatum, RewardAccount,
  RewardAccountDatum, RewardPrices,
}
use core/redeemer.{MintToken}
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

const feed_vkh: FeedVkh = #"1112131415161718191a1b1c1d1e1f2021222324252627"

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

const mock_settings =
  OracleSettingsDatum {
    nodes: [feed_vkh],
    required_node_signatures_count: 1,
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

const platform_output =
  Output {
    address: address.from_script(platform_script_hash),
    value: assets.from_asset(platform_policy_id, platform_nft_name, 1),
    datum: tx.NoDatum,
    reference_script: None,
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

const core_settings_output =
  Output {
    address: address.from_script(oracle_script_hash),
    value: assets.from_asset(
      oracle_policy_id,
      config.core_settings_token_name,
      1,
    ),
    datum: tx.InlineDatum(OracleSettings(mock_settings)),
    reference_script: None,
  }

const minted_value =
  assets.zero
    |> assets.add(oracle_policy_id, config.core_settings_token_name, 1)
    |> assets.add(oracle_policy_id, config.reward_account_token_name, 1)
    |> assets.add(oracle_policy_id, config.aggstate_token_name, 1)

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
      platform_output, core_settings_output, reward_account_output,
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
    Input { output_reference: mock_nfts.utxo_ref, output: platform_output }

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
