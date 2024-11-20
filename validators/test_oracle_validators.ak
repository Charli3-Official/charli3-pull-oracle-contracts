use aiken/collection/list
use aiken/crypto.{ScriptHash}
use cardano/address
use cardano/assets.{PolicyId}
use cardano/transaction.{OutputReference, Transaction}
use cardano/transaction as tx
use config
use ext/aiken/time.{PosixTimeDiff}
use ext/cardano/value.{Asset}
use oracle
use oracle/datum.{
  AggState, FeeConfig, NoRewards, OracleConfiguration, OracleSettings,
  OracleSettingsDatum, RewardAccount, RewardAccountDatum, RewardPrices,
  RewardTransport,
}
use oracle/redeemer.{MintToken}

const twenty_four_hours: PosixTimeDiff = 24 * 60 * 60 * 1000

const one_hour: PosixTimeDiff = 60 * 60 * 1000

const three_minutes: PosixTimeDiff = 3 * 60 * 1000

const mock_manager_script_hash: ScriptHash = "oracle manager script hash"

const mock_oracle_nft_script_hash: ScriptHash = "oracle nft script hash"

const mock_auth_script_hash: ScriptHash = "platform auth script hash"

const mock_platform_auth_policy_id: PolicyId = "platform auth NFT policy id"

const mock_oracle_conf =
  OracleConfiguration {
    platform_auth_nft: mock_platform_auth_policy_id,
    closing_period_length: twenty_four_hours,
    reward_dismissing_period_length: twenty_four_hours,
    fee_token: Asset { policy_id: "C3 policy id", name: "C3" },
  }

const mock_oracle_settings =
  OracleSettingsDatum {
    nodes: [
      Pair("node01 FeedVkh", "node01 PaymentVkh"),
      Pair("node02 FeedVkh", "node02 PaymentVkh"),
      Pair("node03 FeedVkh", "node03 PaymentVkh"),
      Pair("node04 FeedVkh", "node04 PaymentVkh"),
      Pair("node05 FeedVkh", "node05 PaymentVkh"),
      Pair("node06 FeedVkh", "node06 PaymentVkh"),
      Pair("node07 FeedVkh", "node07 PaymentVkh"),
      Pair("node08 FeedVkh", "node08 PaymentVkh"),
      Pair("node09 FeedVkh", "node09 PaymentVkh"),
      Pair("node10 FeedVkh", "node10 PaymentVkh"),
      Pair("node11 FeedVkh", "node11 PaymentVkh"),
      Pair("node12 FeedVkh", "node12 PaymentVkh"),
      Pair("node13 FeedVkh", "node13 PaymentVkh"),
      Pair("node14 FeedVkh", "node14 PaymentVkh"),
      Pair("node15 FeedVkh", "node15 PaymentVkh"),
      Pair("node16 FeedVkh", "node16 PaymentVkh"),
      Pair("node17 FeedVkh", "node17 PaymentVkh"),
    ],
    required_node_signatures_count: 17,
    fee_info: FeeConfig {
      rate_nft: None,
      reward_prices: RewardPrices {
        node_fee: 10_000_000,
        platform_fee: 2_000_000,
      },
    },
    aggregation_liveness_period: one_hour,
    time_absolute_uncertainty: three_minutes,
    iqr_fence_multiplier: 150,
    closing_period_started_at: None,
  }

const mock_platform_nft_value =
  assets.from_asset(mock_platform_auth_policy_id, "Admin", 1)

const mock_platform_nft_output =
  tx.Output {
    address: address.from_script(mock_auth_script_hash),
    value: mock_platform_nft_value,
    datum: tx.NoDatum,
    reference_script: None,
  }

const mock_core_settings_token_value =
  assets.from_asset(
    mock_oracle_nft_script_hash,
    config.core_settings_token_name,
    1,
  )

const mock_reward_account_token_value =
  assets.from_asset(
    mock_oracle_nft_script_hash,
    config.reward_account_token_name,
    1,
  )

const mock_reward_transport_token_value =
  assets.from_asset(
    mock_oracle_nft_script_hash,
    config.reward_transport_token_name,
    1,
  )

const mock_aggstate_token_value =
  assets.from_asset(mock_oracle_nft_script_hash, config.aggstate_token_name, 1)

fn mock_empty_reward_transport_outputs(count: Int) {
  list.repeat(
    tx.Output {
      address: address.from_script(mock_manager_script_hash),
      value: mock_reward_transport_token_value,
      datum: tx.InlineDatum(RewardTransport(NoRewards)),
      reference_script: None,
    },
    count,
  )
}

fn mock_empty_aggstate_outputs(count: Int) {
  list.repeat(
    tx.Output {
      address: address.from_script(mock_manager_script_hash),
      value: mock_aggstate_token_value,
      datum: tx.InlineDatum(AggState(None)),
      reference_script: None,
    },
    count,
  )
}

test successful_oracle_start() {
  let platform_utxo =
    OutputReference { transaction_id: "before start tx", output_index: 0 }
  let platform_input =
    tx.Input {
      output_reference: platform_utxo,
      output: mock_platform_nft_output,
    }
  let minted_tokens_value =
    assets.from_asset_list(
      [
        Pair(
          mock_oracle_nft_script_hash,
          [
            Pair(config.aggstate_token_name, 3),
            Pair(config.core_settings_token_name, 1),
            Pair(config.reward_account_token_name, 1),
            Pair(config.reward_transport_token_name, 3),
          ],
        ),
      ],
    )
  let core_settings_output =
    tx.Output {
      address: address.from_script(mock_manager_script_hash),
      value: mock_core_settings_token_value,
      datum: tx.InlineDatum(OracleSettings(mock_oracle_settings)),
      reference_script: None,
    }
  let reward_account_output =
    tx.Output {
      address: address.from_script(mock_manager_script_hash),
      value: mock_reward_account_token_value,
      datum: tx.InlineDatum(
        RewardAccount(RewardAccountDatum(list.repeat(0, 17))),
      ),
      reference_script: None,
    }
  let reward_transport_outputs = mock_empty_reward_transport_outputs(3)
  let aggstate_outputs = mock_empty_aggstate_outputs(3)

  let start_tx =
    Transaction {
      ..tx.placeholder,
      inputs: [platform_input],
      outputs: [
        mock_platform_nft_output, core_settings_output, reward_account_output,
      ]
        |> list.concat(reward_transport_outputs)
        |> list.concat(aggstate_outputs),
      mint: minted_tokens_value,
    }
  oracle.oracle_nfts.mint(
    platform_utxo,
    mock_oracle_conf,
    mock_manager_script_hash,
    MintToken,
    mock_oracle_nft_script_hash,
    start_tx,
  )
}
