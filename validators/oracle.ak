//// 1. oracle_nfts - this validator will act as one time policy for CoreSettings and RewardAccount
////    and as a scaling policy for RewardTransport with AggState,
////    each policy id is unique for one trade pair (ticker), or potentially even multiple tickers with same nodes and fee token;
//// 2. oracle_manager - main oracle validator, see OracleRedeemer for list of allowed actions.

use aiken/collection/dict
use aiken/collection/list
use aiken/collection/pairs
use aiken/interval
use aiken/math.{abs}
use aiken/option
use cardano/address
use cardano/assets.{PolicyId}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{OutputReference, Transaction}
use cardano/transaction as tx
use config
use ext/cardano/value.{Asset}
use oracle/checks.{
  calculate_asset_net_change_with_default, calculate_minimum_fee_amount,
  check_node_received_reward, check_nodes_update,
  check_pause_does_not_change_settings, check_platform_received_reward,
  check_reward_distribution, check_settings_sanity,
  check_utxo_size_safety_buffer, conserves_utxo_value, convert_reward_prices,
  does_not_produce_own_nft_outputs, find_in_reward_accounts,
  find_node_by_signature, find_out_datum_and_value,
  find_out_datum_and_value_with_allowing_asset, find_referenced_datum,
  is_aggstate_expired, returns_empty_account_outputs,
  returns_empty_aggstate_outputs, spends_one_account_utxo_for_aggregation,
  spends_one_script_utxo_with_nft, spends_protocol_nft_inputs,
  validate_dismissing_period, validate_message_form, validate_settings_form,
}
use oracle/consensus
use oracle/datum.{
  AggState, GenericData, NftsConfiguration, OracleConfiguration, OracleDatum,
  OracleSettings, OracleSettingsDatum, RewardAccount, RewardAccountDatum,
  is_oracle_paused,
}
use oracle/multisig.{check_nodes_multisig}
use oracle/redeemer.{
  AddNodes, BurnToken, DelNodes, DismissRewards, MintToken, MintingRedeemer,
  NodeCollect, OdvAggregate, OdvAggregateMsg, OracleRedeemer, PauseOracle,
  PlatformCollect, RemoveOracle, ResumeOracle, ScaleDown, ScaleToken,
  UpdateSettings,
}
use services/nft_based_auth.{auth_by_nft}
use services/protocol_token.{find_own_protocol_policy_id}
use services/time.{get_current_time}

validator oracle_nfts(nfts_config: NftsConfiguration) {
  mint(redeemer: MintingRedeemer, policy_id: PolicyId, transaction: Transaction) {
    let Transaction { mint, inputs, outputs, reference_inputs, redeemers, .. } =
      transaction

    let minted_assets =
      mint
        |> assets.tokens(policy_id)
    let core_nft = Asset { policy_id, name: config.core_settings_token_name }
    let reward_acc_nft =
      Asset { policy_id, name: config.reward_account_token_name }
    let aggstate_nft = Asset { policy_id, name: config.aggstate_token_name }

    when redeemer is {
      MintToken -> {
        expect Some(1) =
          minted_assets |> dict.get(config.core_settings_token_name)
        expect Some(n) =
          minted_assets |> dict.get(config.reward_account_token_name)
        expect Some(m) = minted_assets |> dict.get(config.aggstate_token_name)
        let must_mint_some_reward_account = n > 0
        let must_mint_same_amount_aggstate = m == n

        expect Some(_input) =
          list.find(
            inputs,
            fn(input) { input.output_reference == nfts_config.utxo_ref },
          )

        expect [(OracleSettings(out_core_datum), _)] =
          find_out_datum_and_value(
            outputs,
            nfts_config.oracle_script_hash,
            core_nft,
          )

        let all_reward_accounts_empty =
          returns_empty_account_outputs(
            nfts_config.oracle_script_hash,
            reward_acc_nft,
            n,
            outputs,
            out_core_datum.utxo_size_safety_buffer,
          )
        let all_aggstate_empty =
          returns_empty_aggstate_outputs(
            nfts_config.oracle_script_hash,
            aggstate_nft,
            m,
            outputs,
          )

        auth_by_nft(nfts_config.oracle_conf.platform_auth_nft, inputs, outputs) && validate_settings_form(
          nfts_config.oracle_conf,
          out_core_datum,
        ) && must_mint_some_reward_account && must_mint_same_amount_aggstate && all_reward_accounts_empty && all_aggstate_empty
      }
      ScaleToken -> {
        expect None = minted_assets |> dict.get(config.core_settings_token_name)
        expect Some(n) =
          minted_assets |> dict.get(config.reward_account_token_name)
        expect Some(m) = minted_assets |> dict.get(config.aggstate_token_name)
        let must_mint_same_amount_aggstate = m == n

        if n > 0 {
          trace @"T1"

          expect OracleSettings(core_datum) =
            find_referenced_datum(
              reference_inputs,
              nfts_config.oracle_script_hash,
              core_nft,
            )

          let all_reward_accounts_empty =
            returns_empty_account_outputs(
              nfts_config.oracle_script_hash,
              reward_acc_nft,
              n,
              outputs,
              core_datum.utxo_size_safety_buffer,
            )
          let all_aggstate_empty =
            returns_empty_aggstate_outputs(
              nfts_config.oracle_script_hash,
              aggstate_nft,
              m,
              outputs,
            )

          let must_not_be_paused = is_oracle_paused(core_datum) |> not

          auth_by_nft(
            nfts_config.oracle_conf.platform_auth_nft,
            inputs,
            outputs,
          ) && must_not_be_paused && must_mint_same_amount_aggstate && all_reward_accounts_empty && all_aggstate_empty
        } else {
          trace @"T2"

          let must_spend_reward_acc_inputs =
            spends_protocol_nft_inputs(
              nfts_config.oracle_script_hash,
              ScaleDown,
              reward_acc_nft,
              abs(n),
              inputs,
              redeemers,
            )
          let must_spend_aggstate_inputs =
            spends_protocol_nft_inputs(
              nfts_config.oracle_script_hash,
              ScaleDown,
              aggstate_nft,
              abs(m),
              inputs,
              redeemers,
            )

          must_spend_reward_acc_inputs && must_spend_aggstate_inputs
        }
      }
      BurnToken -> {
        expect Some(-1) =
          minted_assets |> dict.get(config.core_settings_token_name)
        let n =
          minted_assets
            |> dict.get(config.reward_account_token_name)
            |> option.or_else(0)
        let m =
          minted_assets
            |> dict.get(config.aggstate_token_name)
            |> option.or_else(0)
        let must_not_mint = n <= 0
        let must_burn_same_amount_aggstate = m == n

        let must_spend_core_settings_input =
          spends_one_script_utxo_with_nft(
            nfts_config.oracle_script_hash,
            RemoveOracle,
            core_nft,
            inputs,
            redeemers,
          )

        let must_spend_reward_acc_inputs =
          spends_protocol_nft_inputs(
            nfts_config.oracle_script_hash,
            RemoveOracle,
            reward_acc_nft,
            abs(n),
            inputs,
            redeemers,
          )
        let must_spend_aggstate_inputs =
          spends_protocol_nft_inputs(
            nfts_config.oracle_script_hash,
            RemoveOracle,
            aggstate_nft,
            abs(m),
            inputs,
            redeemers,
          )

        must_spend_core_settings_input && must_not_mint && must_burn_same_amount_aggstate && must_spend_reward_acc_inputs && must_spend_aggstate_inputs
      }
    }
  }

  else(_ctx: ScriptContext) {
    fail @"E1"
  }
}

validator oracle_manager(oracle_conf: OracleConfiguration) {
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
      redeemers,
      ..
    } = transaction

    expect Some(own_input) = tx.find_input(inputs, own_reference)
    expect address.Script(own_hash) =
      own_input.output.address.payment_credential

    let in_value = own_input.output.value

    when (redeemer, in_datum) is {
      // :: OdvAggregate
      (OdvAggregateMsg, AggState(price_data)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, config.aggstate_token_name)
        let reward_account_nft =
          Asset {
            policy_id: nft_policy_id,
            name: config.reward_account_token_name,
          }
        let aggstate_nft =
          Asset { policy_id: nft_policy_id, name: config.aggstate_token_name }

        let must_spend_reward_account_utxo =
          spends_one_account_utxo_for_aggregation(
            own_hash,
            reward_account_nft,
            inputs,
            redeemers,
          )

        expect [(AggState(_), out_value)] =
          find_out_datum_and_value(outputs, own_hash, aggstate_nft)

        is_aggstate_expired(price_data, validity_range) && conserves_utxo_value(
          in_value,
          out_value,
        ) && must_spend_reward_account_utxo
      }
      (OdvAggregate(message), RewardAccount(in_account_datum)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(
            in_value,
            config.reward_account_token_name,
          )
        let reward_account_nft =
          Asset {
            policy_id: nft_policy_id,
            name: config.reward_account_token_name,
          }
        let core_nft =
          Asset {
            policy_id: nft_policy_id,
            name: config.core_settings_token_name,
          }
        let aggstate_nft =
          Asset { policy_id: nft_policy_id, name: config.aggstate_token_name }

        let must_spend_only_one_aggstate_input =
          spends_one_script_utxo_with_nft(
            own_hash,
            OdvAggregateMsg,
            aggstate_nft,
            inputs,
            redeemers,
          )

        expect OracleSettings(core_datum) =
          find_referenced_datum(reference_inputs, own_hash, core_nft)

        expect [(RewardAccount(out_account_datum), out_value)] =
          find_out_datum_and_value_with_allowing_asset(
            outputs,
            own_hash,
            reward_account_nft,
            oracle_conf.fee_token,
          )

        expect [
          (
            AggState(GenericData{price_map: [
              Pair(0, price), Pair(1, time_creation), Pair(2, time_expiration),
            ]}),
            _out_value,
          ),
        ] = find_out_datum_and_value(outputs, own_hash, aggstate_nft)

        let current_time =
          get_current_time(
            core_datum.time_uncertainty_aggregation,
            validity_range,
          )

        let must_have_current_time_as_timestamp =
          current_time == time_creation && current_time == out_account_datum.last_update_time
        let must_expire_in_liveness_period =
          time_expiration == current_time + core_datum.aggregation_liveness_period

        let must_not_be_paused = is_oracle_paused(core_datum) |> not

        let median =
          message.node_feeds_sorted_by_feed
            |> pairs.values
            |> consensus.median(message.node_feeds_count)
        let must_have_correct_median = median == price

        let fees_transferred =
          calculate_asset_net_change_with_default(
            oracle_conf.fee_token,
            in_value,
            out_value,
          )
        let reward_prices =
          convert_reward_prices(
            reference_inputs,
            validity_range,
            core_datum.fee_info.rate_nft,
            core_datum.fee_info.reward_prices,
          )

        let minimum_fee_amount =
          calculate_minimum_fee_amount(reward_prices, message.node_feeds_count)
        let must_transfer_oracle_fees = fees_transferred >= minimum_fee_amount

        validate_message_form(message) && check_nodes_multisig(
          message.node_feeds_sorted_by_feed,
          extra_signatories,
          core_datum.nodes,
          core_datum.required_node_signatures_count,
        ) && check_utxo_size_safety_buffer(
          core_datum.utxo_size_safety_buffer,
          out_value,
        ) && check_reward_distribution(
          message,
          median,
          reward_prices.node_fee,
          in_account_datum.nodes_to_rewards,
          out_account_datum.nodes_to_rewards,
          core_datum.nodes,
          core_datum.iqr_fence_multiplier,
          core_datum.median_divergency_factor,
        ) && must_spend_only_one_aggstate_input && must_have_current_time_as_timestamp && must_expire_in_liveness_period && must_not_be_paused && must_have_correct_median && must_transfer_oracle_fees
      }
      // :: NodeCollect
      (NodeCollect, RewardAccount(in_account_datum)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(
            in_value,
            config.reward_account_token_name,
          )
        let core_nft =
          Asset {
            policy_id: nft_policy_id,
            name: config.core_settings_token_name,
          }
        let reward_acc_nft =
          Asset {
            policy_id: nft_policy_id,
            name: config.reward_account_token_name,
          }

        expect OracleSettings(core_datum) =
          find_referenced_datum(reference_inputs, own_hash, core_nft)

        let total_input_accounts =
          find_in_reward_accounts(
            inputs,
            redeemers,
            own_hash,
            reward_acc_nft,
            NodeCollect,
          )

        let reward_output_accounts =
          find_out_datum_and_value_with_allowing_asset(
            outputs,
            own_hash,
            reward_acc_nft,
            oracle_conf.fee_token,
          )

        check_node_received_reward(
          oracle_conf.fee_token,
          find_node_by_signature(extra_signatories, core_datum.nodes),
          in_account_datum,
          in_value,
          reward_output_accounts,
        ) && total_input_accounts == list.length(reward_output_accounts)
      }
      // :: PlatformCollect
      (PlatformCollect, RewardAccount(in_account_datum)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(
            in_value,
            config.reward_account_token_name,
          )
        let core_nft =
          Asset {
            policy_id: nft_policy_id,
            name: config.core_settings_token_name,
          }
        let reward_acc_nft =
          Asset {
            policy_id: nft_policy_id,
            name: config.reward_account_token_name,
          }

        expect OracleSettings(core_datum) =
          find_referenced_datum(reference_inputs, own_hash, core_nft)

        let total_input_accounts =
          find_in_reward_accounts(
            inputs,
            redeemers,
            own_hash,
            reward_acc_nft,
            PlatformCollect,
          )

        let reward_output_accounts =
          find_out_datum_and_value_with_allowing_asset(
            outputs,
            own_hash,
            reward_acc_nft,
            oracle_conf.fee_token,
          )

        check_platform_received_reward(
          oracle_conf.fee_token,
          core_datum.utxo_size_safety_buffer,
          in_account_datum,
          in_value,
          reward_output_accounts,
        ) && auth_by_nft(oracle_conf.platform_auth_nft, inputs, outputs) && total_input_accounts == list.length(
          reward_output_accounts,
        )
      }
      // :: UpdateSettings
      (UpdateSettings, OracleSettings(in_core_datum)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, config.core_settings_token_name)
        let core_nft =
          Asset {
            policy_id: nft_policy_id,
            name: config.core_settings_token_name,
          }

        expect [(OracleSettings(out_core_datum), out_value)] =
          find_out_datum_and_value(outputs, own_hash, core_nft)

        auth_by_nft(oracle_conf.platform_auth_nft, inputs, outputs) && conserves_utxo_value(
          in_value,
          out_value,
        ) && check_settings_sanity(oracle_conf, in_core_datum, out_core_datum)
      }
      // :: AddNodes
      (AddNodes, OracleSettings(in_core_datum)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, config.core_settings_token_name)
        let core_nft =
          Asset {
            policy_id: nft_policy_id,
            name: config.core_settings_token_name,
          }

        expect [(OracleSettings(out_core_datum), out_value)] =
          find_out_datum_and_value(outputs, own_hash, core_nft)

        auth_by_nft(oracle_conf.platform_auth_nft, inputs, outputs) && conserves_utxo_value(
          in_value,
          out_value,
        ) && check_nodes_update(in_core_datum, out_core_datum, AddNodes)
      }
      // :: DelNodes
      (DelNodes, OracleSettings(in_core_datum)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, config.core_settings_token_name)
        let core_nft =
          Asset {
            policy_id: nft_policy_id,
            name: config.core_settings_token_name,
          }

        expect [(OracleSettings(out_core_datum), out_value)] =
          find_out_datum_and_value(outputs, own_hash, core_nft)

        auth_by_nft(oracle_conf.platform_auth_nft, inputs, outputs) && conserves_utxo_value(
          in_value,
          out_value,
        ) && check_nodes_update(in_core_datum, out_core_datum, DelNodes)
      }
      // :: ScaleDown
      (
        ScaleDown,
        RewardAccount(RewardAccountDatum { nodes_to_rewards, last_update_time }),
      ) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(
            in_value,
            config.reward_account_token_name,
          )
        let must_be_empty_or_expired =
          when nodes_to_rewards is {
            [] -> True
            _ ->
              validate_dismissing_period(
                last_update_time,
                validity_range,
                oracle_conf.reward_dismissing_period_length,
              )
          }

        auth_by_nft(oracle_conf.platform_auth_nft, inputs, outputs) && does_not_produce_own_nft_outputs(
          outputs,
          nft_policy_id,
        ) && must_be_empty_or_expired
      }
      (ScaleDown, AggState(price_data)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, config.aggstate_token_name)

        auth_by_nft(oracle_conf.platform_auth_nft, inputs, outputs) && does_not_produce_own_nft_outputs(
          outputs,
          nft_policy_id,
        ) && is_aggstate_expired(price_data, validity_range)
      }
      // :: DismissRewards
      (
        DismissRewards,
        RewardAccount(RewardAccountDatum { last_update_time, .. }),
      ) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(
            in_value,
            config.reward_account_token_name,
          )
        let core_nft =
          Asset {
            policy_id: nft_policy_id,
            name: config.core_settings_token_name,
          }

        let reward_acc_nft =
          Asset {
            policy_id: nft_policy_id,
            name: config.reward_account_token_name,
          }
        expect OracleSettings(core_datum) =
          find_referenced_datum(reference_inputs, own_hash, core_nft)

        let total_input_accounts =
          find_in_reward_accounts(
            inputs,
            redeemers,
            own_hash,
            reward_acc_nft,
            DismissRewards,
          )

        let must_return_empty_reward_acc_utxos =
          returns_empty_account_outputs(
            own_hash,
            reward_acc_nft,
            total_input_accounts,
            outputs,
            core_datum.utxo_size_safety_buffer,
          )

        auth_by_nft(oracle_conf.platform_auth_nft, inputs, outputs) && must_return_empty_reward_acc_utxos && validate_dismissing_period(
          last_update_time,
          validity_range,
          oracle_conf.reward_dismissing_period_length,
        )
      }
      // :: PauseOracle
      (PauseOracle, OracleSettings(in_core_datum)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, config.core_settings_token_name)
        let core_nft =
          Asset {
            policy_id: nft_policy_id,
            name: config.core_settings_token_name,
          }

        let must_not_be_paused_already = is_oracle_paused(in_core_datum) |> not

        expect [(OracleSettings(out_core_datum), out_value)] =
          find_out_datum_and_value(outputs, own_hash, core_nft)

        let current_time =
          get_current_time(
            in_core_datum.time_uncertainty_platform,
            validity_range,
          )
        let must_start_pause_period =
          out_core_datum.pause_period_started_at == Some(current_time)

        auth_by_nft(oracle_conf.platform_auth_nft, inputs, outputs) && conserves_utxo_value(
          in_value,
          out_value,
        ) && check_pause_does_not_change_settings(in_core_datum, out_core_datum) && must_not_be_paused_already && must_start_pause_period
      }
      // :: ResumeOracle
      (ResumeOracle, OracleSettings(in_core_datum)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, config.core_settings_token_name)
        let core_nft =
          Asset {
            policy_id: nft_policy_id,
            name: config.core_settings_token_name,
          }

        let must_be_paused = is_oracle_paused(in_core_datum)

        expect [(OracleSettings(out_core_datum), out_value)] =
          find_out_datum_and_value(outputs, own_hash, core_nft)

        let must_resume_oracle = is_oracle_paused(out_core_datum) |> not

        auth_by_nft(oracle_conf.platform_auth_nft, inputs, outputs) && conserves_utxo_value(
          in_value,
          out_value,
        ) && check_pause_does_not_change_settings(in_core_datum, out_core_datum) && must_be_paused && must_resume_oracle
      }
      // :: RemoveOracle
      (RemoveOracle, RewardAccount(RewardAccountDatum { .. })) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(
            in_value,
            config.reward_account_token_name,
          )
        let core_nft =
          Asset {
            policy_id: nft_policy_id,
            name: config.core_settings_token_name,
          }

        let must_spend_core_settings_utxo =
          spends_one_script_utxo_with_nft(
            own_hash,
            RemoveOracle,
            core_nft,
            inputs,
            redeemers,
          )

        // nodes which are interested in collecting the rewards should do so during pause period
        must_spend_core_settings_utxo
      }
      (RemoveOracle, AggState(price_data)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, config.aggstate_token_name)
        let core_nft =
          Asset {
            policy_id: nft_policy_id,
            name: config.core_settings_token_name,
          }

        let must_spend_core_settings_utxo =
          spends_one_script_utxo_with_nft(
            own_hash,
            RemoveOracle,
            core_nft,
            inputs,
            redeemers,
          )

        is_aggstate_expired(price_data, validity_range) && must_spend_core_settings_utxo
      }
      (
        RemoveOracle,
        OracleSettings(OracleSettingsDatum { pause_period_started_at, .. }),
      ) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, config.core_settings_token_name)
        let reward_acc_nft =
          Asset {
            policy_id: nft_policy_id,
            name: config.reward_account_token_name,
          }

        let must_spend_reward_account_utxo =
          spends_one_script_utxo_with_nft(
            own_hash,
            RemoveOracle,
            reward_acc_nft,
            inputs,
            redeemers,
          )

        let is_time_to_be_removed =
          pause_period_started_at
            |> option.map(
                fn(pause_start) {
                  interval.is_entirely_after(
                    validity_range,
                    pause_start + oracle_conf.pause_period_length,
                  )
                },
              )
            |> option.or_else(False)

        auth_by_nft(oracle_conf.platform_auth_nft, inputs, outputs) && does_not_produce_own_nft_outputs(
          outputs,
          nft_policy_id,
        ) && is_time_to_be_removed && must_spend_reward_account_utxo
      }
      // ::
      _other -> fail @"E3"
    }
  }

  else(_ctx: ScriptContext) {
    fail @"E2"
  }
}
