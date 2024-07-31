use aiken/transaction/value.{AssetName, PolicyId}

pub type Asset {
  policy_id: PolicyId,
  name: AssetName,
}
