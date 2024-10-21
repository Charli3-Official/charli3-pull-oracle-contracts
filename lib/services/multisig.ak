use aiken/collection/list
use aiken/crypto.{VerificationKeyHash}

/// This type represents an entity with multisig capabilities - e.g. a multisig wallet:
/// * allowed_signatories - Verification key hashed allowed for authorization
/// * required_signatories_count - Minimum required number of signatories for authorization
pub type Multisig {
  allowed_signatories: List<VerificationKeyHash>,
  required_signatories_count: Int,
}

pub fn check_multisig(
  multisig: Multisig,
  tx_signatories: List<VerificationKeyHash>,
) -> Bool {
  trace @"check_multisig"

  let Multisig { allowed_signatories, required_signatories_count } = multisig
  let actual_signatories =
    list.filter(tx_signatories, fn(s) { list.has(allowed_signatories, s) })

  list.length(actual_signatories) >= required_signatories_count
}
