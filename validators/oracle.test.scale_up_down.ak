use aiken/crypto.{ScriptHash}
use cardano/address
use cardano/assets
use cardano/transaction.{Input, Output, OutputReference, Transaction}
use cardano/transaction as tx
use config
use core/datum.{
  AggState, FeeConfig, GenericData, NftsConfiguration, OracleConfiguration,
  OracleSettings, OracleSettingsDatum, RewardAccount, RewardAccountDatum,
  RewardPrices,
}
use core/redeemer.{ScaleDown, ScaleToken}
use oracle

const platform_policy_id: assets.PolicyId =
  #"000102030405060708090a0b0c0d0e0f101112131415161718191a1b"

const oracle_policy_id: assets.PolicyId =
  #"1c1d1e1f202122232425262728292a2b2c2d2e2f30313233343536373839"

const platform_script_hash: ScriptHash =
  #"404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c"

const oracle_script_hash: ScriptHash =
  #"5d5e5f606162636465666768696a6b6c6d6e6f70717273747576777879"

const platform_nft_name = #"504c4154464f524d"

const agg_liveness: Int = 3_600_000

const platform_uncertainty: Int = 600_000

const aggregation_uncertainty: Int = 120_000

const pause_period: Int = 86_400_000

const utxo_buffer: Int = 5_000_000

const mock_nodes =
  [
    "node01               FeedVkh", "node02               FeedVkh",
    "node03               FeedVkh",
  ]

const mock_conf =
  OracleConfiguration {
    platform_auth_nft: platform_policy_id,
    pause_period_length: pause_period,
    reward_dismissing_period_length: pause_period,
    fee_token: None,
  }

const mock_settings =
  OracleSettingsDatum {
    nodes: mock_nodes,
    required_node_signatures_count: 2,
    fee_info: FeeConfig {
      rate_nft: None,
      reward_prices: RewardPrices { node_fee: 1_000_000, platform_fee: 500_000 },
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

const platform_nft_output =
  Output {
    address: address.from_script(platform_script_hash),
    value: assets.from_asset(platform_policy_id, platform_nft_name, 1),
    datum: tx.NoDatum,
    reference_script: None,
  }

const platform_nft_input =
  tx.Input {
    output_reference: OutputReference {
      transaction_id: "platform nft",
      output_index: 0,
    },
    output: platform_nft_output,
  }

const core_settings_input =
  tx.Input {
    output_reference: OutputReference {
      transaction_id: "core settings",
      output_index: 0,
    },
    output: tx.Output {
      address: address.from_script(oracle_script_hash),
      value: assets.from_asset(
        oracle_policy_id,
        config.core_settings_token_name,
        1,
      ),
      datum: tx.InlineDatum(OracleSettings(mock_settings)),
      reference_script: None,
    },
  }

fn mk_reward_output(lovelace: Int) -> Output {
  tx.Output {
    address: address.from_script(oracle_script_hash),
    value: assets.merge(
      assets.from_asset(oracle_policy_id, config.reward_account_token_name, 1),
      assets.from_lovelace(lovelace),
    ),
    datum: tx.InlineDatum(
      RewardAccount(
        RewardAccountDatum { nodes_to_rewards: [], last_update_time: 0 },
      ),
    ),
    reference_script: None,
  }
}

fn mk_aggstate_output(price_map: List<Pair<Int, Int>>) -> Output {
  tx.Output {
    address: address.from_script(oracle_script_hash),
    value: assets.from_asset(oracle_policy_id, config.aggstate_token_name, 1),
    datum: tx.InlineDatum(AggState(GenericData { price_map })),
    reference_script: None,
  }
}

test scale_token_mint_succeeds() {
  let minted_value =
    assets.zero
      |> assets.add(oracle_policy_id, config.reward_account_token_name, 1)
      |> assets.add(oracle_policy_id, config.aggstate_token_name, 1)

  let reward_output = mk_reward_output(utxo_buffer)
  let aggstate_output = mk_aggstate_output([])
  let policy_anchor_input =
    tx.Input {
      output_reference: mock_nfts.utxo_ref,
      output: tx.Output {
        address: address.from_script(platform_script_hash),
        value: assets.from_lovelace(2_000_000),
        datum: tx.NoDatum,
        reference_script: None,
      },
    }

  let tx =
    Transaction {
      ..tx.placeholder,
      inputs: [platform_nft_input, policy_anchor_input],
      reference_inputs: [core_settings_input],
      outputs: [
        platform_nft_output,
        core_settings_input.output,
        reward_output,
        aggstate_output,
      ],
      mint: minted_value,
    }

  oracle.oracle_nfts.mint(mock_nfts, ScaleToken, oracle_policy_id, tx)
}

test scale_down_burn_succeeds() {
  let reward_ref =
    OutputReference { transaction_id: "reward account burn", output_index: 0 }
  let reward_input =
    tx.Input {
      output_reference: reward_ref,
      output: mk_reward_output(utxo_buffer),
    }
  let redeemer_data: Data = ScaleDown
  let tx =
    Transaction {
      ..tx.placeholder,
      reference_inputs: [core_settings_input],
      inputs: [reward_input, platform_nft_input],
      outputs: [platform_nft_output],
      redeemers: [Pair(tx.Spend(reward_ref), redeemer_data)],
    }

  oracle.oracle_manager.spend(
    mock_conf,
    Some(
      RewardAccount(
        RewardAccountDatum { nodes_to_rewards: [], last_update_time: 0 },
      ),
    ),
    ScaleDown,
    reward_ref,
    tx,
  )
}
