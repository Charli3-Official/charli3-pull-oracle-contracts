/// Types of actions for Oracle NFTs (protocol tokens)
/// * MintToken  - Oracle start: one time mint for CoreSettings and RewardAccount; any number of mints for RewardTransport and AggState
/// * ScaleToken - Scale RewardTransport and AggState UTxOs: any number of mints/burns for RewardTransport and AggState
/// * BurnToken  - Oracle close: all tokens are burned
pub type MintingRedeemer {
  MintToken
  ScaleToken
  BurnToken
}

/// Types of actions for Oracle smart contract
/// * OdvAggregate - user sends on demand validation request together with oracle nodes message collected off-chain
/// * CalculateRewards - nodes and platform can calculate reward consensus transferring user provided fees to reward UTxO
/// * NodeCollect - oracle node collects rewards
/// * PlatformCollect - oracle platform collects rewards
/// * UpdateSettings - oracle platform changes consensus settings
/// * SetFeeConfig - oracle platform changes reward fee configuration
/// * AddNodes - oracle platform adds new nodes
/// * DelNodes - oracle platform deletes nodes, WARNING: before deletion all rewards must be calculated and this is not enforced on-chain
/// * ScaleDown - oracle platform burns RewardTransport and AggState NFTs, destroying corresponding UTxOs
/// * DismissRewards - oracle platform turns RewardTransport UTxOs with pending rewards calculations into NoRewards
/// * CloseOracle - oracle platform starts closing period, when nodes can still calculate disregarded rewards
/// * ReopenOracle - redeemer for cancelling oracle close, so that platform can suspend oracle operation only temporarily
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
  ReopenOracle
  RemoveOracle
}
