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
use cardano/assets.{PolicyId}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{OutputReference, Transaction}
use cardano/transaction as tx
use config
use ext/cardano/value.{Asset}
use oracle/checks.{
  calculate_asset_net_change_with_default, calculate_minimum_fee_amount,
  check_added_nodes, check_deleted_nodes_returning, check_node_received_reward,
  check_nodes_final_rewards_paid_returning, check_pause_does_not_change_settings,
  check_platform_received_reward, check_reward_distribution,
  check_settings_sanity, check_utxo_size_safety_buffer, conserves_utxo_value,
  convert_reward_prices, does_not_produce_own_nft_outputs, find_in_aggregations,
  find_in_datum, find_node_index_by_signature, find_out_datum_and_value,
  find_out_datum_and_value_with_allowing_asset, find_referenced_datum,
  is_aggstate_expired, oracle_fees_were_transferred,
  returns_empty_aggstate_outputs, returns_empty_reward_outputs,
  spends_one_script_utxo_with_nft, spends_protocol_nft_inputs,
  validate_message_form, validate_settings_form,
}
use oracle/consensus
use oracle/datum.{
  GenericData, NoRewards, OracleConfiguration, OracleDatum, OracleSettings,
  OracleSettingsDatum, RewardAccount, RewardAccountDatum, RewardConsensusPending,
  RewardTransport, StandardOracleDatum, is_oracle_paused,
}
use oracle/multisig.{check_nodes_multisig}
use oracle/redeemer.{
  AddNodes, BurnToken, CalculateRewards, DelNodes, DismissRewards, MintToken,
  MintingRedeemer, NodeCollect, OdvAggregate, OracleRedeemer, PauseOracle,
  PlatformCollect, RemoveOracle, ResumeOracle, ScaleDown, ScaleToken,
  UpdateSettings,
}
use services/nft_based_auth.{auth_by_nft}
use services/protocol_token.{find_own_protocol_policy_id}
use services/time.{get_current_time}

validator oracle_nfts(
  utxo_ref: OutputReference,
  oracle_conf: OracleConfiguration,
  oracle_script_hash: ScriptHash,
) {
  mint(redeemer: MintingRedeemer, policy_id: PolicyId, transaction: Transaction) {
    let Transaction { mint, inputs, outputs, reference_inputs, redeemers, .. } =
      transaction

    let minted_assets =
      mint
        |> assets.tokens(policy_id)
    let core_nft = Asset { policy_id, name: config.core_settings_token_name }
    let reward_acc_nft =
      Asset { policy_id, name: config.reward_account_token_name }
    let reward_transport_nft =
      Asset { policy_id, name: config.reward_transport_token_name }
    let aggstate_nft = Asset { policy_id, name: config.aggstate_token_name }

    when redeemer is {
      MintToken -> {
        expect Some(1) =
          minted_assets |> dict.get(config.core_settings_token_name)
        expect Some(1) =
          minted_assets |> dict.get(config.reward_account_token_name)
        expect Some(n) =
          minted_assets |> dict.get(config.reward_transport_token_name)
        expect Some(m) = minted_assets |> dict.get(config.aggstate_token_name)
        let must_mint_some_reward_transport = n > 0
        let must_mint_same_amount_aggstate = m == n

        expect Some(_input) =
          list.find(inputs, fn(input) { input.output_reference == utxo_ref })

        expect (OracleSettings(out_core_datum), _) =
          find_out_datum_and_value(outputs, oracle_script_hash, core_nft)

        expect (RewardAccount(_), _) =
          find_out_datum_and_value(outputs, oracle_script_hash, reward_acc_nft)

        let must_return_empty_reward_utxos =
          returns_empty_reward_outputs(
            oracle_script_hash,
            reward_transport_nft,
            n,
            outputs,
            out_core_datum.utxo_size_safety_buffer,
          )
        let must_return_empty_aggstate_utxos =
          returns_empty_aggstate_outputs(
            oracle_script_hash,
            aggstate_nft,
            m,
            outputs,
          )

        auth_by_nft(oracle_conf.platform_auth_nft, inputs, outputs) && validate_settings_form(
          oracle_conf,
          out_core_datum,
        ) && must_mint_some_reward_transport && must_mint_same_amount_aggstate && must_return_empty_reward_utxos && must_return_empty_aggstate_utxos
      }
      ScaleToken -> {
        expect None = minted_assets |> dict.get(config.core_settings_token_name)
        expect None =
          minted_assets |> dict.get(config.reward_account_token_name)
        expect Some(n) =
          minted_assets |> dict.get(config.reward_transport_token_name)
        expect Some(m) = minted_assets |> dict.get(config.aggstate_token_name)
        let must_mint_same_amount_aggstate = m == n

        if n > 0 {
          trace @"T1"

          expect OracleSettings(core_datum) =
            find_referenced_datum(
              reference_inputs,
              oracle_script_hash,
              core_nft,
            )

          let must_return_empty_reward_utxos =
            returns_empty_reward_outputs(
              oracle_script_hash,
              reward_transport_nft,
              n,
              outputs,
              core_datum.utxo_size_safety_buffer,
            )
          let must_return_empty_aggstate_utxos =
            returns_empty_aggstate_outputs(
              oracle_script_hash,
              aggstate_nft,
              m,
              outputs,
            )

          let must_not_be_paused = is_oracle_paused(core_datum) |> not

          auth_by_nft(oracle_conf.platform_auth_nft, inputs, outputs) && must_not_be_paused && must_mint_same_amount_aggstate && must_return_empty_reward_utxos && must_return_empty_aggstate_utxos
        } else {
          trace @"T2"

          let must_spend_reward_transport_inputs =
            spends_protocol_nft_inputs(
              oracle_script_hash,
              ScaleDown,
              reward_transport_nft,
              abs(n),
              inputs,
              redeemers,
            )
          let must_spend_aggstate_inputs =
            spends_protocol_nft_inputs(
              oracle_script_hash,
              ScaleDown,
              aggstate_nft,
              abs(m),
              inputs,
              redeemers,
            )

          must_spend_reward_transport_inputs && must_spend_aggstate_inputs
        }
      }
      BurnToken -> {
        expect Some(-1) =
          minted_assets |> dict.get(config.core_settings_token_name)
        expect Some(-1) =
          minted_assets |> dict.get(config.reward_account_token_name)
        let n =
          minted_assets
            |> dict.get(config.reward_transport_token_name)
            |> option.or_else(0)
        let m =
          minted_assets
            |> dict.get(config.aggstate_token_name)
            |> option.or_else(0)
        let must_not_mint_reward_transport = n <= 0
        let must_burn_same_amount_aggstate = m == n

        let must_spend_core_settings_input =
          spends_one_script_utxo_with_nft(
            oracle_script_hash,
            RemoveOracle,
            core_nft,
            inputs,
            redeemers,
          )
        let must_spend_reward_account_input =
          spends_one_script_utxo_with_nft(
            oracle_script_hash,
            RemoveOracle,
            reward_acc_nft,
            inputs,
            redeemers,
          )

        let must_spend_reward_transport_inputs =
          spends_protocol_nft_inputs(
            oracle_script_hash,
            RemoveOracle,
            reward_transport_nft,
            abs(n),
            inputs,
            redeemers,
          )
        let must_spend_aggstate_inputs =
          spends_protocol_nft_inputs(
            oracle_script_hash,
            RemoveOracle,
            aggstate_nft,
            abs(m),
            inputs,
            redeemers,
          )

        must_spend_core_settings_input && must_spend_reward_account_input && must_not_mint_reward_transport && must_burn_same_amount_aggstate && must_spend_reward_transport_inputs && must_spend_aggstate_inputs
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
      (OdvAggregate, StandardOracleDatum(price_data)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, config.aggstate_token_name)
        let reward_transport_nft =
          Asset {
            policy_id: nft_policy_id,
            name: config.reward_transport_token_name,
          }
        let aggstate_nft =
          Asset { policy_id: nft_policy_id, name: config.aggstate_token_name }

        let must_spend_reward_transport_utxo =
          spends_one_script_utxo_with_nft(
            own_hash,
            OdvAggregate,
            reward_transport_nft,
            inputs,
            redeemers,
          )

        expect (StandardOracleDatum(_), out_value) =
          find_out_datum_and_value(outputs, own_hash, aggstate_nft)

        is_aggstate_expired(price_data, validity_range) && conserves_utxo_value(
          in_value,
          out_value,
        ) && must_spend_reward_transport_utxo
      }
      (OdvAggregate, RewardTransport(NoRewards)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(
            in_value,
            config.reward_transport_token_name,
          )
        let reward_transport_nft =
          Asset {
            policy_id: nft_policy_id,
            name: config.reward_transport_token_name,
          }
        let core_nft =
          Asset {
            policy_id: nft_policy_id,
            name: config.core_settings_token_name,
          }
        let aggstate_nft =
          Asset { policy_id: nft_policy_id, name: config.aggstate_token_name }

        let must_spend_only_one_reward_input =
          spends_one_script_utxo_with_nft(
            own_hash,
            OdvAggregate,
            reward_transport_nft,
            inputs,
            redeemers,
          )
        let must_spend_only_one_aggstate_input =
          spends_one_script_utxo_with_nft(
            own_hash,
            OdvAggregate,
            aggstate_nft,
            inputs,
            redeemers,
          )

        expect OracleSettings(core_datum) =
          find_referenced_datum(reference_inputs, own_hash, core_nft)

        expect (RewardTransport(RewardConsensusPending(aggregation)), out_value) =
          find_out_datum_and_value_with_allowing_asset(
            outputs,
            own_hash,
            reward_transport_nft,
            oracle_conf.fee_token,
          )

        expect (
          StandardOracleDatum(GenericData([
            Pair(0, price), Pair(1, time_creation), Pair(2, time_expiration),
          ])),
          _out_value,
        ) = find_out_datum_and_value(outputs, own_hash, aggstate_nft)

        let current_time =
          get_current_time(
            core_datum.time_uncertainty_aggregation,
            validity_range,
          )

        let must_have_current_time_as_timestamp =
          current_time == aggregation.message.timestamp && current_time == time_creation
        let must_expire_in_liveness_period =
          time_expiration == current_time + core_datum.aggregation_liveness_period

        let must_not_be_paused = is_oracle_paused(core_datum) |> not

        let median =
          aggregation.message.node_feeds_sorted_by_feed
            |> pairs.values
            |> consensus.median(aggregation.message.node_feeds_count)
        let must_have_correct_median =
          median == aggregation.oracle_feed && median == price

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
        let must_tell_node_reward_price =
          reward_prices.node_fee == aggregation.node_reward_price
        let minimum_fee_amount =
          calculate_minimum_fee_amount(
            reward_prices,
            aggregation.message.node_feeds_count,
          )
        let must_transfer_oracle_fees =
          fees_transferred >= aggregation.rewards_amount_paid && aggregation.rewards_amount_paid >= minimum_fee_amount

        validate_message_form(aggregation.message) && check_nodes_multisig(
          aggregation.message.node_feeds_sorted_by_feed,
          extra_signatories,
          core_datum.nodes,
          core_datum.required_node_signatures_count,
        ) && check_utxo_size_safety_buffer(
          core_datum.utxo_size_safety_buffer,
          out_value,
        ) && must_spend_only_one_reward_input && must_spend_only_one_aggstate_input && must_have_current_time_as_timestamp && must_expire_in_liveness_period && must_not_be_paused && must_have_correct_median && must_transfer_oracle_fees && must_tell_node_reward_price
      }
      // :: CalculateRewards
      (CalculateRewards, RewardTransport(RewardConsensusPending { .. })) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(
            in_value,
            config.reward_transport_token_name,
          )
        let reward_acc_nft =
          Asset {
            policy_id: nft_policy_id,
            name: config.reward_account_token_name,
          }

        let must_spend_reward_account_utxo =
          spends_one_script_utxo_with_nft(
            own_hash,
            CalculateRewards,
            reward_acc_nft,
            inputs,
            redeemers,
          )

        must_spend_reward_account_utxo
      }
      (CalculateRewards, RewardAccount(in_account_datum)) -> {
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
        let reward_transport_nft =
          Asset {
            policy_id: nft_policy_id,
            name: config.reward_transport_token_name,
          }
        let reward_acc_nft =
          Asset {
            policy_id: nft_policy_id,
            name: config.reward_account_token_name,
          }

        expect OracleSettings(core_datum) =
          find_referenced_datum(reference_inputs, own_hash, core_nft)

        expect (RewardAccount(out_account_datum), out_value) =
          find_out_datum_and_value_with_allowing_asset(
            outputs,
            own_hash,
            reward_acc_nft,
            oracle_conf.fee_token,
          )

        let aggregations =
          find_in_aggregations(
            inputs,
            redeemers,
            own_hash,
            reward_transport_nft,
            CalculateRewards,
          )
        let must_return_empty_reward_utxos =
          returns_empty_reward_outputs(
            own_hash,
            reward_transport_nft,
            list.length(aggregations),
            outputs,
            core_datum.utxo_size_safety_buffer,
          )

        // TODO make sure this is extra safe, because it is allowed for anyone to calculate rewards
        oracle_fees_were_transferred(
          oracle_conf.fee_token,
          aggregations,
          in_value,
          out_value,
          core_datum.utxo_size_safety_buffer,
        ) && check_reward_distribution(
          aggregations,
          in_account_datum.nodes_to_rewards,
          out_account_datum.nodes_to_rewards,
          core_datum.nodes,
          core_datum.iqr_fence_multiplier,
        ) && must_return_empty_reward_utxos
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

        expect (RewardAccount(out_account_datum), out_value) =
          find_out_datum_and_value_with_allowing_asset(
            outputs,
            own_hash,
            reward_acc_nft,
            oracle_conf.fee_token,
          )

        let rewarded_node =
          find_node_index_by_signature(extra_signatories, core_datum.nodes)

        check_node_received_reward(
          oracle_conf.fee_token,
          rewarded_node,
          in_account_datum.nodes_to_rewards,
          out_account_datum.nodes_to_rewards,
          in_value,
          out_value,
        ) && check_utxo_size_safety_buffer(
          core_datum.utxo_size_safety_buffer,
          out_value,
        )
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

        expect (RewardAccount(out_account_datum), out_value) =
          find_out_datum_and_value_with_allowing_asset(
            outputs,
            own_hash,
            reward_acc_nft,
            oracle_conf.fee_token,
          )

        let datum_left_unchanged = in_account_datum == out_account_datum

        auth_by_nft(oracle_conf.platform_auth_nft, inputs, outputs) && check_platform_received_reward(
          oracle_conf.fee_token,
          core_datum.utxo_size_safety_buffer,
          in_account_datum.nodes_to_rewards,
          in_value,
          out_value,
        ) && datum_left_unchanged
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

        expect (OracleSettings(out_core_datum), out_value) =
          find_out_datum_and_value(outputs, own_hash, core_nft)

        auth_by_nft(oracle_conf.platform_auth_nft, inputs, outputs) && conserves_utxo_value(
          in_value,
          out_value,
        ) && check_settings_sanity(oracle_conf, in_core_datum, out_core_datum)
      }
      // :: AddNodes
      (AddNodes, RewardAccount(_in_account_datum)) -> {
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

        let must_spend_core_settings_utxo =
          spends_one_script_utxo_with_nft(
            own_hash,
            AddNodes,
            core_nft,
            inputs,
            redeemers,
          )

        expect (RewardAccount(_out_account_datum), out_value) =
          find_out_datum_and_value_with_allowing_asset(
            outputs,
            own_hash,
            reward_acc_nft,
            oracle_conf.fee_token,
          )

        conserves_utxo_value(in_value, out_value) && must_spend_core_settings_utxo
      }
      (AddNodes, OracleSettings(in_core_datum)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, config.core_settings_token_name)
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

        expect (OracleSettings(out_core_datum), out_value) =
          find_out_datum_and_value(outputs, own_hash, core_nft)

        expect RewardAccount(in_account_datum) =
          find_in_datum(inputs, redeemers, own_hash, AddNodes, reward_acc_nft)

        expect (RewardAccount(out_account_datum), _) =
          find_out_datum_and_value_with_allowing_asset(
            outputs,
            own_hash,
            reward_acc_nft,
            oracle_conf.fee_token,
          )

        auth_by_nft(oracle_conf.platform_auth_nft, inputs, outputs) && conserves_utxo_value(
          in_value,
          out_value,
        ) && check_added_nodes(
          in_core_datum,
          out_core_datum,
          in_account_datum.nodes_to_rewards,
          out_account_datum.nodes_to_rewards,
        )
      }
      // :: DelNodes
      (DelNodes, OracleSettings(_in_core_datum)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, config.core_settings_token_name)
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

        let must_spend_reward_account_utxo =
          spends_one_script_utxo_with_nft(
            own_hash,
            DelNodes,
            reward_acc_nft,
            inputs,
            redeemers,
          )

        expect (OracleSettings(_out_core_datum), out_value) =
          find_out_datum_and_value(outputs, own_hash, core_nft)

        conserves_utxo_value(in_value, out_value) && must_spend_reward_account_utxo
      }
      (DelNodes, RewardAccount(in_account_datum)) -> {
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

        expect OracleSettings(in_core_datum) =
          find_in_datum(inputs, redeemers, own_hash, DelNodes, core_nft)

        expect (OracleSettings(out_core_datum), _) =
          find_out_datum_and_value(outputs, own_hash, core_nft)

        expect (RewardAccount(out_account_datum), out_value) =
          find_out_datum_and_value_with_allowing_asset(
            outputs,
            own_hash,
            reward_acc_nft,
            oracle_conf.fee_token,
          )

        let deleted_nodes =
          check_deleted_nodes_returning(
            in_core_datum,
            out_core_datum,
            in_account_datum.nodes_to_rewards,
            out_account_datum.nodes_to_rewards,
          )

        let current_time =
          get_current_time(
            in_core_datum.time_uncertainty_platform,
            validity_range,
          )
        let final_rewards_amount =
          check_nodes_final_rewards_paid_returning(
            oracle_conf,
            outputs,
            in_core_datum,
            in_account_datum.nodes_to_rewards,
            deleted_nodes,
            current_time,
          )
        let amount_withdrawn =
          calculate_asset_net_change_with_default(
            oracle_conf.fee_token,
            in_value,
            out_value,
          )
            |> fn(v) { -v }
        let must_withdraw_final_rewards =
          final_rewards_amount == amount_withdrawn

        auth_by_nft(oracle_conf.platform_auth_nft, inputs, outputs) && check_utxo_size_safety_buffer(
          in_core_datum.utxo_size_safety_buffer,
          out_value,
        ) && must_withdraw_final_rewards
      }
      // :: ScaleDown
      (ScaleDown, RewardTransport(NoRewards)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(
            in_value,
            config.reward_transport_token_name,
          )

        auth_by_nft(oracle_conf.platform_auth_nft, inputs, outputs) && does_not_produce_own_nft_outputs(
          outputs,
          nft_policy_id,
        )
      }
      (ScaleDown, StandardOracleDatum(price_data)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(in_value, config.aggstate_token_name)

        auth_by_nft(oracle_conf.platform_auth_nft, inputs, outputs) && does_not_produce_own_nft_outputs(
          outputs,
          nft_policy_id,
        ) && is_aggstate_expired(price_data, validity_range)
      }
      // :: DismissRewards
      (DismissRewards, RewardTransport(RewardConsensusPending(aggregation))) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(
            in_value,
            config.reward_transport_token_name,
          )
        let core_nft =
          Asset {
            policy_id: nft_policy_id,
            name: config.core_settings_token_name,
          }
        let reward_transport_nft =
          Asset {
            policy_id: nft_policy_id,
            name: config.reward_transport_token_name,
          }

        expect OracleSettings(core_datum) =
          find_referenced_datum(reference_inputs, own_hash, core_nft)

        let aggregations =
          find_in_aggregations(
            inputs,
            redeemers,
            own_hash,
            reward_transport_nft,
            DismissRewards,
          )

        let must_return_empty_reward_utxos =
          returns_empty_reward_outputs(
            own_hash,
            reward_transport_nft,
            list.length(aggregations),
            outputs,
            core_datum.utxo_size_safety_buffer,
          )

        let must_be_after_dismissing_period =
          interval.is_entirely_after(
            validity_range,
            aggregation.message.timestamp + oracle_conf.reward_dismissing_period_length,
          )

        auth_by_nft(oracle_conf.platform_auth_nft, inputs, outputs) && must_return_empty_reward_utxos && must_be_after_dismissing_period
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

        expect (OracleSettings(out_core_datum), out_value) =
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

        expect (OracleSettings(out_core_datum), out_value) =
          find_out_datum_and_value(outputs, own_hash, core_nft)

        let must_resume_oracle = is_oracle_paused(out_core_datum) |> not

        auth_by_nft(oracle_conf.platform_auth_nft, inputs, outputs) && conserves_utxo_value(
          in_value,
          out_value,
        ) && check_pause_does_not_change_settings(in_core_datum, out_core_datum) && must_be_paused && must_resume_oracle
      }
      // :: RemoveOracle
      (RemoveOracle, RewardAccount(_)) -> {
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
      (RemoveOracle, RewardTransport(NoRewards)) -> {
        let nft_policy_id =
          find_own_protocol_policy_id(
            in_value,
            config.reward_transport_token_name,
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

        must_spend_core_settings_utxo
      }
      (RemoveOracle, StandardOracleDatum(price_data)) -> {
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
