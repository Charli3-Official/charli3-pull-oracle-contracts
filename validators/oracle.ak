//// 1. oracle_nfts - this validator will act as one time policy for RewardAccount
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
use cardano/assets.{AssetName, PolicyId, ada_policy_id}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{OutputReference, Transaction}
use cardano/transaction as tx
use ext/cardano/value.{Asset}
use oracle/checks.{
  are_mutable_settings_unchanged, calculate_minimum_fee_amout,
  convert_reward_prices, does_not_produce_own_nft_outputs, find_in_aggregations,
  find_in_datum, find_out_datum_and_value, is_aggstate_expired,
  oracle_fees_were_transfered, returns_empty_aggstate_outputs,
  returns_empty_reward_outputs, spends_reward_acc_utxo,
}
use oracle/consensus
use oracle/datum.{
  AggState, NoRewards, OracleDatum, OracleSettings, RewardAccount,
  RewardConsensusPending, RewardDatum, RewardTransport, is_oracle_closing,
}
use services/nft_based_auth.{auth_by_nft}
use services/protocol_token.{
  find_own_protocol_policy_id, spends_protocol_nft_inputs,
}
use services/time.{get_current_time}

pub const reward_acc_token_name: AssetName = "RewardAcc"

pub const reward_transport_token_name: AssetName = "RewardT"

pub const aggstate_token_name: AssetName = "AggState"

/// Types of actions for Oracle NFTs (protocol tokens)
/// * Mint  - Oracle start: one time mint for RewardAccount; any number of mints for RewardTransport and AggState
/// * Scale - Scale RewardTransport and AggState UTxOs: any number of mints/burns for RewardTransport and AggState
/// * Burn  - Oracle close: all tokens are burned
pub type MintingRedeemer {
  Mint
  Scale
  Burn
}

/// Types of actions for Oracle smart contract
/// * OdvAggregate - user sends on demand validation request together with oracle nodes message collected off-chain
/// * CalculateRewards - nodes and platform can calculate reward consensus transferring user provided fees to reward UTxO
/// * NodeCollect - oracle node collects rewards
/// * PlatformCollect - oracle platform collects rewards
/// * UpdateSettings - oracle platform changes consensus settings
/// * SetFeeConfig - oracle platform changes reward fee configuration
/// * AddNodes - oracle platform adds new nodes
/// * DelNodes - oracle platform deletes nodes
/// * ScaleDown - oracle platform burns RewardTransport and AggState NFTs, destroying corresponding UTxOs
/// * DismissRewards - oracle platform turns RewardTransport UTxOs with pending rewards calculations into NoRewards
/// * CloseOracle - oracle platform starts closing period, when nodes can still calculate disregarded rewards
/// * RemoveOracle - oracle closing period ends and platform destroys all UTxOs and all NFTs
pub type OracleRedeemer {
  OdvAggregate
  CalculateRewards
  NodeCollect
  PlatformCollect
  UpdateSettings
  SetFeeConfig
  AddNodes
  DelNodes
  ScaleDown
  DismissRewards
  CloseOracle
  // TODO implement ReopenOracle - redeemer for cancelling oracle close?
  RemoveOracle
}

validator oracle_nfts(
  utxo_ref: OutputReference,
  settings: OracleSettings,
  oracle_script_hash: ScriptHash,
) {
  mint(redeemer: MintingRedeemer, policy_id: PolicyId, transaction: Transaction) {
    let Transaction { mint, inputs, outputs, reference_inputs, .. } =
      transaction

    let minted_assets =
      mint
        |> assets.tokens(policy_id)
    let reward_acc_nft = Asset { policy_id, name: reward_acc_token_name }
    let reward_transport_nft =
      Asset { policy_id, name: reward_transport_token_name }
    let aggstate_nft = Asset { policy_id, name: aggstate_token_name }

    when redeemer is {
      Mint -> {
        expect Some(1) = minted_assets |> dict.get(reward_acc_token_name)
        expect Some(n) = minted_assets |> dict.get(reward_transport_token_name)
        expect Some(m) = minted_assets |> dict.get(aggstate_token_name)
        let must_mint_some_reward_transport = n > 0
        let must_mint_same_amount_aggstate = m == n

        expect Some(_input) =
          list.find(inputs, fn(input) { input.output_reference == utxo_ref })

        expect (RewardAccount(_), _) =
          find_out_datum_and_value(
            outputs,
            oracle_script_hash,
            reward_acc_nft,
            ada_policy_id,
          )

        let must_return_empty_reward_utxos =
          returns_empty_reward_outputs(
            oracle_script_hash,
            reward_transport_nft,
            ada_policy_id,
            n,
            outputs,
          )
        let must_return_empty_aggstate_utxos =
          returns_empty_aggstate_outputs(
            oracle_script_hash,
            aggstate_nft,
            ada_policy_id,
            m,
            outputs,
          )

        auth_by_nft(settings.platform_auth_nft, inputs, outputs) && must_mint_some_reward_transport? && must_mint_same_amount_aggstate? && must_return_empty_reward_utxos && must_return_empty_aggstate_utxos
      }
      Scale -> {
        expect None = minted_assets |> dict.get(reward_acc_token_name)
        expect Some(n) = minted_assets |> dict.get(reward_transport_token_name)
        expect Some(m) = minted_assets |> dict.get(aggstate_token_name)
        let must_mint_same_amount_aggstate = m == n

        if n > 0 {
          trace @"scale up"

          expect RewardAccount(core_datum) =
            find_in_datum(reference_inputs, oracle_script_hash, reward_acc_nft)

          let must_return_empty_reward_utxos =
            returns_empty_reward_outputs(
              oracle_script_hash,
              reward_transport_nft,
              ada_policy_id,
              n,
              outputs,
            )
          let must_return_empty_aggstate_utxos =
            returns_empty_aggstate_outputs(
              oracle_script_hash,
              aggstate_nft,
              ada_policy_id,
              m,
              outputs,
            )

          let must_not_be_closing = is_oracle_closing(core_datum) |> not

          auth_by_nft(settings.platform_auth_nft, inputs, outputs) && must_not_be_closing? && must_mint_same_amount_aggstate? && must_return_empty_reward_utxos && must_return_empty_aggstate_utxos
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
      Burn -> {
        expect Some(-1) = minted_assets |> dict.get(reward_acc_token_name)
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

        spends_reward_acc_utxo(oracle_script_hash, reward_acc_nft, inputs) && must_not_mint_reward_transport? && must_mint_same_amount_aggstate? && must_spend_reward_transport_inputs? && must_spend_aggstate_inputs?
      }
    }
  }

  else(_ctx: ScriptContext) {
    fail @"validator supports only mint purpose"
  }
}

validator oracle_manager(settings: OracleSettings) {
  // TODO check some datum pieces had been left immutable
  // TODO check value is untouched
  spend(
    own_datum: Option<OracleDatum>,
    redeemer: OracleRedeemer,
    own_reference: OutputReference,
    transaction: Transaction,
  ) {
    expect Some(in_datum) = own_datum

    let Transaction { inputs, outputs, reference_inputs, validity_range, .. } =
      transaction

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
          find_out_datum_and_value(
            outputs,
            own_hash,
            aggstate_nft,
            ada_policy_id,
          )

        let must_conserve_value = in_value == out_value

        is_aggstate_expired(aggstate, validity_range) && must_spend_reward_transport_utxo? && must_conserve_value?
      }
      (OdvAggregate, RewardTransport(NoRewards)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, reward_transport_token_name)
        let reward_transport_nft =
          Asset { policy_id: nft_policy_id, name: reward_transport_token_name }
        let reward_acc_nft =
          Asset { policy_id: nft_policy_id, name: reward_acc_token_name }
        let aggstate_nft =
          Asset { policy_id: nft_policy_id, name: aggstate_token_name }

        let must_spend_only_one_reward_input =
          spends_protocol_nft_inputs(own_hash, reward_transport_nft, 1, inputs)
        let must_spend_only_one_aggstate_input =
          spends_protocol_nft_inputs(own_hash, aggstate_nft, 1, inputs)

        expect RewardAccount(core_datum) =
          find_in_datum(reference_inputs, own_hash, reward_acc_nft)

        expect (
          RewardTransport(RewardConsensusPending { message, oracle_feed }),
          out_value,
        ) =
          find_out_datum_and_value(
            outputs,
            own_hash,
            reward_transport_nft,
            settings.fee_token.policy_id,
          )

        expect (AggState(Some(aggstate)), _out_value) =
          find_out_datum_and_value(
            outputs,
            own_hash,
            aggstate_nft,
            ada_policy_id,
          )

        let current_time =
          get_current_time(core_datum.time_absolute_uncertainty, validity_range)

        let must_have_current_time_as_timestamp =
          current_time == message.timestamp && current_time == aggstate.created_at
        let must_expire_in_liveness_period =
          aggstate.expiry_timestamp == current_time + core_datum.aggregation_liveness_period

        let must_not_be_closing = is_oracle_closing(core_datum) |> not

        let median =
          message.node_feeds
            |> pairs.values
            |> consensus.median
        let must_have_correct_median =
          median == oracle_feed && median == aggstate.oracle_feed

        let fees_transfered =
          assets.negate(in_value)
            |> assets.merge(out_value, _)
            |> assets.quantity_of(
                settings.fee_token.policy_id,
                settings.fee_token.name,
              )
        let minimum_fee_amout =
          convert_reward_prices(
            reference_inputs,
            validity_range,
            core_datum.fee_info.rate_nft,
            core_datum.fee_info.reward_prices,
          )
            |> calculate_minimum_fee_amout(list.length(message.node_feeds))
        let must_transfer_oracle_fees = fees_transfered >= minimum_fee_amout

        // TODO multisig check
        must_spend_only_one_reward_input? && must_spend_only_one_aggstate_input? && must_have_current_time_as_timestamp? && must_expire_in_liveness_period? && must_not_be_closing? && must_have_correct_median? && must_transfer_oracle_fees?
      }
      // :: CalculateRewards
      (CalculateRewards, RewardTransport(RewardConsensusPending { .. })) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, reward_transport_token_name)
        let reward_acc_nft =
          Asset { policy_id: nft_policy_id, name: reward_acc_token_name }

        spends_reward_acc_utxo(own_hash, reward_acc_nft, inputs)
      }
      (CalculateRewards, RewardAccount(in_core_datum)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, reward_acc_token_name)
        let reward_transport_nft =
          Asset { policy_id: nft_policy_id, name: reward_transport_token_name }
        let reward_acc_nft =
          Asset { policy_id: nft_policy_id, name: reward_acc_token_name }

        expect (RewardAccount(out_core_datum), out_value) =
          find_out_datum_and_value(
            outputs,
            own_hash,
            reward_acc_nft,
            settings.fee_token.policy_id,
          )

        let aggregations =
          find_in_aggregations(inputs, own_hash, reward_transport_nft)
        let must_return_empty_reward_utxos =
          returns_empty_reward_outputs(
            own_hash,
            reward_transport_nft,
            ada_policy_id,
            list.length(aggregations),
            outputs,
          )

        // TODO make sure this is extra safe, because it is allowed for anyone to calculate rewards
        // TODO rewards consensus checks
        are_mutable_settings_unchanged(in_core_datum, out_core_datum) && oracle_fees_were_transfered(
          settings.fee_token,
          aggregations,
          in_value,
          out_value,
        ) && must_return_empty_reward_utxos
      }
      // :: NodeCollect
      (NodeCollect, RewardAccount(in_core_datum)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, reward_acc_token_name)
        let reward_acc_nft =
          Asset { policy_id: nft_policy_id, name: reward_acc_token_name }

        expect (RewardAccount(out_core_datum), _out_value) =
          find_out_datum_and_value(
            outputs,
            own_hash,
            reward_acc_nft,
            settings.fee_token.policy_id,
          )

        // TODO node signature check
        // TODO node rewards check
        are_mutable_settings_unchanged(in_core_datum, out_core_datum)
      }
      // :: PlatformCollect
      (PlatformCollect, RewardAccount(in_core_datum)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, reward_acc_token_name)
        let reward_acc_nft =
          Asset { policy_id: nft_policy_id, name: reward_acc_token_name }

        expect (RewardAccount(out_core_datum), _out_value) =
          find_out_datum_and_value(
            outputs,
            own_hash,
            reward_acc_nft,
            settings.fee_token.policy_id,
          )

        let datum_left_unchanged = in_core_datum == out_core_datum

        // TODO platform rewards check
        auth_by_nft(settings.platform_auth_nft, inputs, outputs) && datum_left_unchanged?
      }
      // :: UpdateSettings
      (UpdateSettings, RewardAccount(RewardDatum { .. })) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, reward_acc_token_name)
        let reward_acc_nft =
          Asset { policy_id: nft_policy_id, name: reward_acc_token_name }

        expect (RewardAccount(_), _out_value) =
          find_out_datum_and_value(
            outputs,
            own_hash,
            reward_acc_nft,
            settings.fee_token.policy_id,
          )

        // TODO settings sanity check
        auth_by_nft(settings.platform_auth_nft, inputs, outputs)
      }
      // :: SetFeeConfig
      (SetFeeConfig, RewardAccount(RewardDatum { .. })) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, reward_acc_token_name)
        let reward_acc_nft =
          Asset { policy_id: nft_policy_id, name: reward_acc_token_name }

        expect (RewardAccount(_), _out_value) =
          find_out_datum_and_value(
            outputs,
            own_hash,
            reward_acc_nft,
            settings.fee_token.policy_id,
          )

        // TODO fee config sanity check
        auth_by_nft(settings.platform_auth_nft, inputs, outputs)
      }
      // :: AddNodes
      (AddNodes, RewardAccount(RewardDatum { .. })) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, reward_acc_token_name)
        let reward_acc_nft =
          Asset { policy_id: nft_policy_id, name: reward_acc_token_name }

        expect (RewardAccount(_), _out_value) =
          find_out_datum_and_value(
            outputs,
            own_hash,
            reward_acc_nft,
            settings.fee_token.policy_id,
          )

        // TODO new reward distribution == 0 check
        auth_by_nft(settings.platform_auth_nft, inputs, outputs)
      }
      // :: DelNodes
      (DelNodes, RewardAccount(RewardDatum { .. })) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, reward_acc_token_name)
        let reward_acc_nft =
          Asset { policy_id: nft_policy_id, name: reward_acc_token_name }

        expect (RewardAccount(_), _out_value) =
          find_out_datum_and_value(
            outputs,
            own_hash,
            reward_acc_nft,
            settings.fee_token.policy_id,
          )

        // TODO reward distribution check
        auth_by_nft(settings.platform_auth_nft, inputs, outputs)
      }
      // :: ScaleDown
      (ScaleDown, RewardTransport(NoRewards)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, reward_transport_token_name)

        auth_by_nft(settings.platform_auth_nft, inputs, outputs) && does_not_produce_own_nft_outputs(
          outputs,
          nft_policy_id,
        )
      }
      (ScaleDown, AggState(aggstate)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, aggstate_token_name)

        auth_by_nft(settings.platform_auth_nft, inputs, outputs) && does_not_produce_own_nft_outputs(
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

        let must_return_empty_reward_utxos =
          returns_empty_reward_outputs(
            own_hash,
            reward_transport_nft,
            ada_policy_id,
            1,
            outputs,
          )

        let must_be_after_dismissing_period =
          interval.is_entirely_after(
            validity_range,
            message.timestamp + settings.reward_dismissing_period_length,
          )

        auth_by_nft(settings.platform_auth_nft, inputs, outputs) && must_return_empty_reward_utxos && must_be_after_dismissing_period?
      }
      // :: CloseOracle
      (CloseOracle, RewardAccount(in_core_datum)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, reward_acc_token_name)
        let reward_acc_nft =
          Asset { policy_id: nft_policy_id, name: reward_acc_token_name }

        let must_not_be_closing_already =
          is_oracle_closing(in_core_datum) |> not

        expect (RewardAccount(out_core_datum), _out_value) =
          find_out_datum_and_value(
            outputs,
            own_hash,
            reward_acc_nft,
            settings.fee_token.policy_id,
          )

        let current_time =
          get_current_time(
            in_core_datum.time_absolute_uncertainty,
            validity_range,
          )
        let must_start_closing_period =
          out_core_datum.closing_period_started_at == Some(current_time)

        let must_not_change_other_settings =
          in_core_datum.nodes_to_rewards == out_core_datum.nodes_to_rewards && in_core_datum.fee_info == out_core_datum.fee_info && in_core_datum.aggregation_liveness_period == out_core_datum.aggregation_liveness_period && in_core_datum.time_absolute_uncertainty == out_core_datum.time_absolute_uncertainty

        auth_by_nft(settings.platform_auth_nft, inputs, outputs) && must_not_be_closing_already? && must_start_closing_period? && must_not_change_other_settings?
      }
      // :: RemoveOracle
      (RemoveOracle, RewardTransport(NoRewards)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, reward_transport_token_name)
        let reward_acc_nft =
          Asset { policy_id: nft_policy_id, name: reward_acc_token_name }

        spends_reward_acc_utxo(own_hash, reward_acc_nft, inputs)
      }
      (RemoveOracle, AggState(aggstate)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, aggstate_token_name)
        let reward_acc_nft =
          Asset { policy_id: nft_policy_id, name: reward_acc_token_name }

        spends_reward_acc_utxo(own_hash, reward_acc_nft, inputs) && is_aggstate_expired(
          aggstate,
          validity_range,
        )
      }
      (
        RemoveOracle,
        RewardAccount(RewardDatum { closing_period_started_at, .. }),
      ) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, reward_acc_token_name)

        let is_time_to_be_removed =
          closing_period_started_at
            |> option.map(
                fn(closing_start) {
                  interval.is_entirely_after(
                    validity_range,
                    closing_start + settings.closing_period_length,
                  )
                },
              )
            |> option.or_else(False)

        auth_by_nft(settings.platform_auth_nft, inputs, outputs) && does_not_produce_own_nft_outputs(
          outputs,
          nft_policy_id,
        ) && is_time_to_be_removed?
      }
      // ::
      _other -> fail @"Oracle Script state transition not allowed"
    }
  }

  else(_ctx: ScriptContext) {
    fail @"validator supports only spend purpose"
  }
}
