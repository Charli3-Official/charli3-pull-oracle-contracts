use oracle/datum.{AggregateMessage}

/// Types of actions for Oracle NFTs (protocol tokens)
/// * MintToken  - Oracle start: one time mint for CoreSettings and RewardAccount; any number of mints for RewardTransport and AggState
/// * ScaleToken - Scale RewardTransport and AggState UTxOs: any number of mints/burns for RewardTransport and AggState
/// * BurnToken  - Oracle remove: all tokens are burned
pub type MintingRedeemer {
  MintToken
  ScaleToken
  BurnToken
}

/// Types of actions for Oracle smart contract
/// * OdvAggregate - user sends on demand validation request together with oracle nodes message collected off-chain
/// * NodeCollect - oracle node collects rewards
/// * PlatformCollect - oracle platform collects rewards
/// * UpdateSettings - oracle platform changes consensus, timing or fee settings
/// * AddNodes - oracle platform adds new nodes
/// * DelNodes - oracle platform deletes nodes
/// * ScaleDown - oracle platform burns RewardTransport and AggState NFTs, destroying corresponding UTxOs
/// * DismissRewards - oracle platform turns RewardTransport UTxOs with pending rewards calculations into NoRewards
/// * PauseOracle - oracle platform starts pause period, when nodes can still calculate disregarded rewards
/// * ResumeOracle - redeemer for cancelling oracle pause, so that platform can suspend oracle operation only temporarily
/// * RemoveOracle - oracle pause period ends and platform destroys all UTxOs and all NFTs
pub type OracleRedeemer {
  OdvAggregate(AggregateMessage)
  OdvAggregateMsg
  NodeCollect
  PlatformCollect
  UpdateSettings
  AddNodes
  DelNodes
  ScaleDown
  DismissRewards
  PauseOracle
  ResumeOracle
  RemoveOracle
}
