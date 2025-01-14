use aiken/collection/list
use aiken/interval
use aiken/option
use cardano/assets
use cardano/transaction.{OutputReference, Transaction} as tx
use services/nft_based_auth.{auth_by_nft}
use services/reward_escrow.{
  ReceiveReward, ReturnToIssuer, RewardEscrowDatum, RewardEscrowRedeemer,
}

validator reward_escrow_manager {
  spend(
    own_datum: Option<RewardEscrowDatum>,
    redeemer: RewardEscrowRedeemer,
    own_reference: OutputReference,
    transaction: Transaction,
  ) {
    expect Some(RewardEscrowDatum {
      reward_issuer_nft,
      escrow_expiration_timestamp,
      reward_receiver,
      reward_issuer_address,
    }) = own_datum

    let Transaction { inputs, outputs, validity_range, extra_signatories, .. } =
      transaction

    when redeemer is {
      ReceiveReward -> {
        expect Some(own_input) = tx.find_input(inputs, own_reference)
        let in_value = own_input.output.value

        let must_be_signed_by_receiver =
          list.has(extra_signatories, reward_receiver)

        let utxo_fee = assets.lovelace_of(in_value)
        expect Some(paid_to_issuer) =
          list.find(outputs, fn(out) { out.address == reward_issuer_address })
            |> option.map(fn(out) { assets.lovelace_of(out.value) })
        let must_pay_utxo_fee_to_issuer = paid_to_issuer >= utxo_fee

        must_be_signed_by_receiver? && must_pay_utxo_fee_to_issuer?
      }
      ReturnToIssuer -> {
        let must_be_after_expiration =
          interval.is_entirely_after(
            validity_range,
            escrow_expiration_timestamp,
          )

        auth_by_nft(reward_issuer_nft, inputs, outputs) && must_be_after_expiration?
      }
    }
  }

  else(_) {
    fail
  }
}
