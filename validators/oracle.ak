//// 1. oracle_nfts - this validator will act as one time policy for CoreSettings and RewardAccount
////    and as a scaling policy for RewardTransport with AggState,
////    each policy id is unique for one trade pair (ticker), or potentially even multiple tickers with same nodes and fee token;
//// 2. oracle_manager - main oracle validator, see OracleRedeemer for list of allowed actions.

use aiken/collection/dict
use aiken/collection/list
use aiken/collection/pairs
use aiken/crypto.{ScriptHash}
use aiken/interval
use aiken/math.{abs}
use aiken/option
use cardano/address
use cardano/assets.{AssetName, PolicyId}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{OutputReference, Transaction}
use cardano/transaction as tx
use ext/cardano/value.{Asset}
use oracle/checks.{
  calculate_minimum_fee_amout, check_closing_does_not_change_settings,
  check_fee_settings_sanity, check_reward_distribution, check_settings_sanity,
  convert_reward_prices, does_not_produce_own_nft_outputs, find_in_aggregations,
  find_in_datum, find_out_datum_and_value,
  find_out_datum_and_value_allowing_asset, is_aggstate_expired,
  oracle_fees_were_transfered, returns_empty_aggstate_outputs,
  returns_empty_reward_outputs, validate_message_form,
}
use oracle/consensus
use oracle/datum.{
  AggState, NoRewards, OracleConfiguration, OracleDatum, OracleSettings,
  OracleSettingsDatum, RewardAccount, RewardAccountDatum, RewardConsensusPending,
  RewardTransport, is_oracle_closing,
}
use oracle/multisig.{check_nodes_multisig}
use oracle/redeemer.{
  AddNodes, BurnToken, CalculateRewards, CloseOracle, DelNodes, DismissRewards,
  MintToken, MintingRedeemer, NodeCollect, OdvAggregate, OracleRedeemer,
  PlatformCollect, RemoveOracle, ReopenOracle, ScaleDown, ScaleToken,
  SetFeeConfig, UpdateSettings,
}
use services/nft_based_auth.{auth_by_nft}
use services/protocol_token.{
  find_own_protocol_policy_id, spends_protocol_nft_inputs,
  spends_script_utxo_with_nft,
}
use services/time.{get_current_time}

// TODO move constants to toml config or to env
pub const core_settings_token_name: AssetName = "CoreSettings"

pub const reward_account_token_name: AssetName = "RewardAccount"

pub const reward_transport_token_name: AssetName = "RewardT"

pub const aggstate_token_name: AssetName = "AggState"

validator oracle_nfts(
  utxo_ref: OutputReference,
  config: OracleConfiguration,
  oracle_script_hash: ScriptHash,
) {
  mint(redeemer: MintingRedeemer, policy_id: PolicyId, transaction: Transaction) {
    let Transaction { mint, inputs, outputs, reference_inputs, .. } =
      transaction

    let minted_assets =
      mint
        |> assets.tokens(policy_id)
    let core_nft = Asset { policy_id, name: core_settings_token_name }
    let reward_acc_nft = Asset { policy_id, name: reward_account_token_name }
    let reward_transport_nft =
      Asset { policy_id, name: reward_transport_token_name }
    let aggstate_nft = Asset { policy_id, name: aggstate_token_name }

    when redeemer is {
      MintToken -> {
        expect Some(1) = minted_assets |> dict.get(core_settings_token_name)
        expect Some(1) = minted_assets |> dict.get(reward_account_token_name)
        expect Some(n) = minted_assets |> dict.get(reward_transport_token_name)
        expect Some(m) = minted_assets |> dict.get(aggstate_token_name)
        let must_mint_some_reward_transport = n > 0
        let must_mint_same_amount_aggstate = m == n

        expect Some(_input) =
          list.find(inputs, fn(input) { input.output_reference == utxo_ref })

        expect (OracleSettings(_), _) =
          find_out_datum_and_value(outputs, oracle_script_hash, core_nft)

        expect (RewardAccount(_), _) =
          find_out_datum_and_value(outputs, oracle_script_hash, reward_acc_nft)

        let must_return_empty_reward_utxos =
          returns_empty_reward_outputs(
            oracle_script_hash,
            reward_transport_nft,
            n,
            outputs,
          )
        let must_return_empty_aggstate_utxos =
          returns_empty_aggstate_outputs(
            oracle_script_hash,
            aggstate_nft,
            m,
            outputs,
          )

        auth_by_nft(config.platform_auth_nft, inputs, outputs) && must_mint_some_reward_transport? && must_mint_same_amount_aggstate? && must_return_empty_reward_utxos && must_return_empty_aggstate_utxos
      }
      ScaleToken -> {
        expect None = minted_assets |> dict.get(core_settings_token_name)
        expect None = minted_assets |> dict.get(reward_account_token_name)
        expect Some(n) = minted_assets |> dict.get(reward_transport_token_name)
        expect Some(m) = minted_assets |> dict.get(aggstate_token_name)
        let must_mint_same_amount_aggstate = m == n

        if n > 0 {
          trace @"scale up"

          expect OracleSettings(core_datum) =
            find_in_datum(reference_inputs, oracle_script_hash, core_nft)

          let must_return_empty_reward_utxos =
            returns_empty_reward_outputs(
              oracle_script_hash,
              reward_transport_nft,
              n,
              outputs,
            )
          let must_return_empty_aggstate_utxos =
            returns_empty_aggstate_outputs(
              oracle_script_hash,
              aggstate_nft,
              m,
              outputs,
            )

          let must_not_be_closing = is_oracle_closing(core_datum) |> not

          auth_by_nft(config.platform_auth_nft, inputs, outputs) && must_not_be_closing? && must_mint_same_amount_aggstate? && must_return_empty_reward_utxos && must_return_empty_aggstate_utxos
        } else {
          trace @"scale down"

          let must_spend_reward_transport_inputs =
            spends_protocol_nft_inputs(
              oracle_script_hash,
              reward_transport_nft,
              abs(n),
              inputs,
            )
          let must_spend_aggstate_inputs =
            spends_protocol_nft_inputs(
              oracle_script_hash,
              aggstate_nft,
              abs(m),
              inputs,
            )

          must_spend_reward_transport_inputs? && must_spend_aggstate_inputs?
        }
      }
      BurnToken -> {
        expect Some(-1) = minted_assets |> dict.get(core_settings_token_name)
        expect Some(-1) = minted_assets |> dict.get(reward_account_token_name)
        let n =
          minted_assets
            |> dict.get(reward_transport_token_name)
            |> option.or_else(0)
        let m =
          minted_assets
            |> dict.get(aggstate_token_name)
            |> option.or_else(0)
        let must_not_mint_reward_transport = n <= 0
        let must_mint_same_amount_aggstate = m == n

        let must_spend_core_settings_input =
          spends_script_utxo_with_nft(oracle_script_hash, core_nft, inputs)
        let must_spend_reward_account_input =
          spends_script_utxo_with_nft(
            oracle_script_hash,
            reward_acc_nft,
            inputs,
          )

        let must_spend_reward_transport_inputs =
          spends_protocol_nft_inputs(
            oracle_script_hash,
            reward_transport_nft,
            abs(n),
            inputs,
          )
        let must_spend_aggstate_inputs =
          spends_protocol_nft_inputs(
            oracle_script_hash,
            aggstate_nft,
            abs(m),
            inputs,
          )

        must_spend_core_settings_input? && must_spend_reward_account_input? && must_not_mint_reward_transport? && must_mint_same_amount_aggstate? && must_spend_reward_transport_inputs? && must_spend_aggstate_inputs?
      }
    }
  }

  else(_ctx: ScriptContext) {
    fail @"validator supports only mint purpose"
  }
}

validator oracle_manager(config: OracleConfiguration) {
  // TODO check some datum pieces had been left immutable
  // TODO check value is untouched
  spend(
    own_datum: Option<OracleDatum>,
    redeemer: OracleRedeemer,
    own_reference: OutputReference,
    transaction: Transaction,
  ) {
    expect Some(in_datum) = own_datum

    let Transaction {
      inputs,
      outputs,
      reference_inputs,
      validity_range,
      extra_signatories,
      ..
    } = transaction

    expect Some(own_input) = tx.find_input(inputs, own_reference)
    expect address.Script(own_hash) =
      own_input.output.address.payment_credential

    let in_value = own_input.output.value

    when (redeemer, in_datum) is {
      // :: OdvAggregate
      (OdvAggregate, AggState(aggstate)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, aggstate_token_name)
        let reward_transport_nft =
          Asset { policy_id: nft_policy_id, name: reward_transport_token_name }
        let aggstate_nft =
          Asset { policy_id: nft_policy_id, name: aggstate_token_name }

        let must_spend_reward_transport_utxo =
          spends_protocol_nft_inputs(own_hash, reward_transport_nft, 1, inputs)

        expect (AggState(_), out_value) =
          find_out_datum_and_value(outputs, own_hash, aggstate_nft)

        let must_conserve_value = in_value == out_value

        is_aggstate_expired(aggstate, validity_range) && must_spend_reward_transport_utxo? && must_conserve_value?
      }
      (OdvAggregate, RewardTransport(NoRewards)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, reward_transport_token_name)
        let reward_transport_nft =
          Asset { policy_id: nft_policy_id, name: reward_transport_token_name }
        let core_nft =
          Asset { policy_id: nft_policy_id, name: core_settings_token_name }
        let aggstate_nft =
          Asset { policy_id: nft_policy_id, name: aggstate_token_name }

        let must_spend_only_one_reward_input =
          spends_protocol_nft_inputs(own_hash, reward_transport_nft, 1, inputs)
        let must_spend_only_one_aggstate_input =
          spends_protocol_nft_inputs(own_hash, aggstate_nft, 1, inputs)

        expect OracleSettings(core_datum) =
          find_in_datum(reference_inputs, own_hash, core_nft)

        expect (
          RewardTransport(RewardConsensusPending { message, oracle_feed }),
          out_value,
        ) =
          find_out_datum_and_value_allowing_asset(
            outputs,
            own_hash,
            reward_transport_nft,
            config.fee_token.policy_id,
          )

        expect (AggState(Some(aggstate)), _out_value) =
          find_out_datum_and_value(outputs, own_hash, aggstate_nft)

        let current_time =
          get_current_time(core_datum.time_absolute_uncertainty, validity_range)

        let must_have_current_time_as_timestamp =
          current_time == message.timestamp && current_time == aggstate.created_at
        let must_expire_in_liveness_period =
          aggstate.expiry_timestamp == current_time + core_datum.aggregation_liveness_period

        let must_not_be_closing = is_oracle_closing(core_datum) |> not

        let median =
          message.node_feeds_sorted_by_feed
            |> pairs.values
            |> consensus.median(message.node_feeds_count)
        let must_have_correct_median =
          median == oracle_feed && median == aggstate.oracle_feed

        let fees_transfered =
          assets.quantity_of(
            out_value,
            config.fee_token.policy_id,
            config.fee_token.name,
          ) - assets.quantity_of(
            in_value,
            config.fee_token.policy_id,
            config.fee_token.name,
          )
        let minimum_fee_amout =
          convert_reward_prices(
            reference_inputs,
            validity_range,
            core_datum.fee_info.rate_nft,
            core_datum.fee_info.reward_prices,
          )
            |> calculate_minimum_fee_amout(message.node_feeds_count)
        let must_transfer_oracle_fees = fees_transfered >= minimum_fee_amout

        validate_message_form(message) && check_nodes_multisig(
          message.node_feeds_sorted_by_feed,
          extra_signatories,
          core_datum.nodes,
          core_datum.required_node_signatures_count,
        ) && must_spend_only_one_reward_input? && must_spend_only_one_aggstate_input? && must_have_current_time_as_timestamp? && must_expire_in_liveness_period? && must_not_be_closing? && must_have_correct_median? && must_transfer_oracle_fees?
      }
      // :: CalculateRewards
      (CalculateRewards, RewardTransport(RewardConsensusPending { .. })) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, reward_transport_token_name)
        let reward_acc_nft =
          Asset { policy_id: nft_policy_id, name: reward_account_token_name }

        let must_spend_reward_account_utxo =
          spends_script_utxo_with_nft(own_hash, reward_acc_nft, inputs)

        must_spend_reward_account_utxo?
      }
      (CalculateRewards, RewardAccount(in_account_datum)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, reward_account_token_name)
        let core_nft =
          Asset { policy_id: nft_policy_id, name: core_settings_token_name }
        let reward_transport_nft =
          Asset { policy_id: nft_policy_id, name: reward_transport_token_name }
        let reward_acc_nft =
          Asset { policy_id: nft_policy_id, name: reward_account_token_name }

        expect OracleSettings(core_datum) =
          find_in_datum(reference_inputs, own_hash, core_nft)

        expect (RewardAccount(out_account_datum), out_value) =
          find_out_datum_and_value_allowing_asset(
            outputs,
            own_hash,
            reward_acc_nft,
            config.fee_token.policy_id,
          )

        let aggregations =
          find_in_aggregations(inputs, own_hash, reward_transport_nft)
        let must_return_empty_reward_utxos =
          returns_empty_reward_outputs(
            own_hash,
            reward_transport_nft,
            list.length(aggregations),
            outputs,
          )

        // TODO make sure this is extra safe, because it is allowed for anyone to calculate rewards
        oracle_fees_were_transfered(
          config.fee_token,
          aggregations,
          in_value,
          out_value,
        ) && check_reward_distribution(
          aggregations,
          in_account_datum.nodes_to_rewards,
          out_account_datum.nodes_to_rewards,
          core_datum.fee_info.reward_prices,
          core_datum.iqr_fence_multiplier,
        ) && must_return_empty_reward_utxos
      }
      // :: NodeCollect
      (NodeCollect, RewardAccount(in_account_datum)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, reward_account_token_name)
        let reward_acc_nft =
          Asset { policy_id: nft_policy_id, name: reward_account_token_name }

        expect (RewardAccount(out_account_datum), _out_value) =
          find_out_datum_and_value_allowing_asset(
            outputs,
            own_hash,
            reward_acc_nft,
            config.fee_token.policy_id,
          )

        let check_nodes_count =
          list.length(in_account_datum.nodes_to_rewards) == list.length(
            out_account_datum.nodes_to_rewards,
          )

        // TODO node signature check
        // TODO node rewards check
        check_nodes_count?
      }
      // :: PlatformCollect
      (PlatformCollect, RewardAccount(in_core_datum)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, reward_account_token_name)
        let reward_acc_nft =
          Asset { policy_id: nft_policy_id, name: reward_account_token_name }

        expect (RewardAccount(out_core_datum), _out_value) =
          find_out_datum_and_value_allowing_asset(
            outputs,
            own_hash,
            reward_acc_nft,
            config.fee_token.policy_id,
          )

        let datum_left_unchanged = in_core_datum == out_core_datum

        // TODO platform rewards check
        auth_by_nft(config.platform_auth_nft, inputs, outputs) && datum_left_unchanged?
      }
      // :: UpdateSettings
      (UpdateSettings, OracleSettings(in_core_datum)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, core_settings_token_name)
        let core_nft =
          Asset { policy_id: nft_policy_id, name: core_settings_token_name }

        expect (OracleSettings(out_core_datum), out_value) =
          find_out_datum_and_value(outputs, own_hash, core_nft)

        let must_conserve_value = in_value == out_value

        auth_by_nft(config.platform_auth_nft, inputs, outputs) && check_settings_sanity(
          in_core_datum,
          out_core_datum,
        ) && must_conserve_value?
      }
      // :: SetFeeConfig
      (SetFeeConfig, OracleSettings(in_core_datum)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, core_settings_token_name)
        let core_nft =
          Asset { policy_id: nft_policy_id, name: core_settings_token_name }

        expect (OracleSettings(out_core_datum), out_value) =
          find_out_datum_and_value(outputs, own_hash, core_nft)

        let must_be_closing = is_oracle_closing(in_core_datum)

        let must_conserve_value = in_value == out_value

        auth_by_nft(config.platform_auth_nft, inputs, outputs) && check_fee_settings_sanity(
          in_core_datum,
          out_core_datum,
        ) && must_be_closing? && must_conserve_value?
      }
      // :: AddNodes
      (AddNodes, RewardAccount(_in_account_datum)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, reward_account_token_name)
        let core_nft =
          Asset { policy_id: nft_policy_id, name: core_settings_token_name }
        let reward_acc_nft =
          Asset { policy_id: nft_policy_id, name: reward_account_token_name }

        let must_spend_core_settings_utxo =
          spends_script_utxo_with_nft(own_hash, core_nft, inputs)

        expect (RewardAccount(_out_account_datum), _out_value) =
          find_out_datum_and_value_allowing_asset(
            outputs,
            own_hash,
            reward_acc_nft,
            config.fee_token.policy_id,
          )

        // TODO new reward distribution == 0 check
        must_spend_core_settings_utxo?
      }
      (AddNodes, OracleSettings(OracleSettingsDatum { .. })) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, core_settings_token_name)
        let core_nft =
          Asset { policy_id: nft_policy_id, name: core_settings_token_name }
        let reward_acc_nft =
          Asset { policy_id: nft_policy_id, name: reward_account_token_name }

        let must_spend_reward_account_utxo =
          spends_script_utxo_with_nft(own_hash, reward_acc_nft, inputs)

        expect (OracleSettings(_), _out_value) =
          find_out_datum_and_value(outputs, own_hash, core_nft)

        // TODO check new node pkhs added
        // TODO should be closing
        auth_by_nft(config.platform_auth_nft, inputs, outputs) && must_spend_reward_account_utxo?
      }
      // :: DelNodes
      (DelNodes, RewardAccount(_in_account_datum)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, reward_account_token_name)
        let core_nft =
          Asset { policy_id: nft_policy_id, name: core_settings_token_name }
        let reward_acc_nft =
          Asset { policy_id: nft_policy_id, name: reward_account_token_name }

        let must_spend_core_settings_utxo =
          spends_script_utxo_with_nft(own_hash, core_nft, inputs)

        expect (RewardAccount(_out_account_datum), _out_value) =
          find_out_datum_and_value_allowing_asset(
            outputs,
            own_hash,
            reward_acc_nft,
            config.fee_token.policy_id,
          )

        // TODO reward distribution check
        must_spend_core_settings_utxo?
      }
      (DelNodes, OracleSettings(OracleSettingsDatum { .. })) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, core_settings_token_name)
        let core_nft =
          Asset { policy_id: nft_policy_id, name: core_settings_token_name }
        let reward_acc_nft =
          Asset { policy_id: nft_policy_id, name: reward_account_token_name }

        let must_spend_reward_account_utxo =
          spends_script_utxo_with_nft(own_hash, reward_acc_nft, inputs)

        expect (OracleSettings(_), _out_value) =
          find_out_datum_and_value(outputs, own_hash, core_nft)

        // TODO should be closing
        // TODO check node pkhs removed
        auth_by_nft(config.platform_auth_nft, inputs, outputs) && must_spend_reward_account_utxo?
      }
      // :: ScaleDown
      (ScaleDown, RewardTransport(NoRewards)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, reward_transport_token_name)

        auth_by_nft(config.platform_auth_nft, inputs, outputs) && does_not_produce_own_nft_outputs(
          outputs,
          nft_policy_id,
        )
      }
      (ScaleDown, AggState(aggstate)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, aggstate_token_name)

        auth_by_nft(config.platform_auth_nft, inputs, outputs) && does_not_produce_own_nft_outputs(
          outputs,
          nft_policy_id,
        ) && is_aggstate_expired(aggstate, validity_range)
      }
      // :: DismissRewards
      (DismissRewards, RewardTransport(RewardConsensusPending { message, .. })) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, reward_transport_token_name)
        let reward_transport_nft =
          Asset { policy_id: nft_policy_id, name: reward_transport_token_name }

        let must_return_empty_reward_utxo =
          returns_empty_reward_outputs(
            own_hash,
            reward_transport_nft,
            1,
            outputs,
          )

        let must_be_after_dismissing_period =
          interval.is_entirely_after(
            validity_range,
            message.timestamp + config.reward_dismissing_period_length,
          )

        auth_by_nft(config.platform_auth_nft, inputs, outputs) && must_return_empty_reward_utxo && must_be_after_dismissing_period?
      }
      // :: CloseOracle
      (CloseOracle, OracleSettings(in_core_datum)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, core_settings_token_name)
        let core_nft =
          Asset { policy_id: nft_policy_id, name: core_settings_token_name }

        let must_not_be_closing_already =
          is_oracle_closing(in_core_datum) |> not

        expect (OracleSettings(out_core_datum), out_value) =
          find_out_datum_and_value(outputs, own_hash, core_nft)

        let current_time =
          get_current_time(
            in_core_datum.time_absolute_uncertainty,
            validity_range,
          )
        let must_start_closing_period =
          out_core_datum.closing_period_started_at == Some(current_time)

        let must_conserve_value = in_value == out_value

        auth_by_nft(config.platform_auth_nft, inputs, outputs) && check_closing_does_not_change_settings(
          in_core_datum,
          out_core_datum,
        ) && must_not_be_closing_already? && must_start_closing_period? && must_conserve_value?
      }
      // :: ReopenOracle
      (ReopenOracle, OracleSettings(in_core_datum)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, core_settings_token_name)
        let core_nft =
          Asset { policy_id: nft_policy_id, name: core_settings_token_name }

        let must_be_closing = is_oracle_closing(in_core_datum)

        expect (OracleSettings(out_core_datum), out_value) =
          find_out_datum_and_value(outputs, own_hash, core_nft)

        let must_open_oracle = is_oracle_closing(out_core_datum) |> not

        let must_conserve_value = in_value == out_value

        auth_by_nft(config.platform_auth_nft, inputs, outputs) && check_closing_does_not_change_settings(
          in_core_datum,
          out_core_datum,
        ) && must_be_closing? && must_open_oracle? && must_conserve_value?
      }
      // :: RemoveOracle
      (RemoveOracle, RewardAccount(_)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, reward_account_token_name)
        let core_nft =
          Asset { policy_id: nft_policy_id, name: core_settings_token_name }

        let must_spend_core_settings_utxo =
          spends_script_utxo_with_nft(own_hash, core_nft, inputs)

        // nodes which are interested in collecting the rewards should do so during closing period
        must_spend_core_settings_utxo?
      }

      (RemoveOracle, RewardTransport(NoRewards)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, reward_transport_token_name)
        let core_nft =
          Asset { policy_id: nft_policy_id, name: core_settings_token_name }

        let must_spend_core_settings_utxo =
          spends_script_utxo_with_nft(own_hash, core_nft, inputs)

        must_spend_core_settings_utxo?
      }
      (RemoveOracle, AggState(aggstate)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, aggstate_token_name)
        let core_nft =
          Asset { policy_id: nft_policy_id, name: core_settings_token_name }

        let must_spend_core_settings_utxo =
          spends_script_utxo_with_nft(own_hash, core_nft, inputs)

        is_aggstate_expired(aggstate, validity_range) && must_spend_core_settings_utxo?
      }
      (
        RemoveOracle,
        OracleSettings(OracleSettingsDatum { closing_period_started_at, .. }),
      ) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, core_settings_token_name)
        let reward_acc_nft =
          Asset { policy_id: nft_policy_id, name: reward_account_token_name }

        let must_spend_reward_account_utxo =
          spends_script_utxo_with_nft(own_hash, reward_acc_nft, inputs)

        let is_time_to_be_removed =
          closing_period_started_at
            |> option.map(
                fn(closing_start) {
                  interval.is_entirely_after(
                    validity_range,
                    closing_start + config.closing_period_length,
                  )
                },
              )
            |> option.or_else(False)

        auth_by_nft(config.platform_auth_nft, inputs, outputs) && does_not_produce_own_nft_outputs(
          outputs,
          nft_policy_id,
        ) && is_time_to_be_removed? && must_spend_reward_account_utxo?
      }
      // ::
      _other -> fail @"Oracle Script state transition not allowed"
    }
  }

  else(_ctx: ScriptContext) {
    fail @"validator supports only spend purpose"
  }
}
