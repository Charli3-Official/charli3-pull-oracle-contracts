use aiken/builtin
use aiken/collection/list
use aiken/math/rational
use aiken/option
use ext/aiken/math/rational.{Percent, per_cent} as ext
use oracle/datum.{NodeFeed, NodeId, OracleFeed}

pub fn median(
  node_feeds_sorted: List<NodeFeed>,
  node_feeds_count: Int,
) -> OracleFeed {
  if node_feeds_count % 2 == 0 {
    option.map2(
      list.at(node_feeds_sorted, node_feeds_count / 2),
      list.at(node_feeds_sorted, node_feeds_count / 2 - 1),
      fn(a, b) { ( a + b ) / 2 },
    )
  } else {
    list.at(node_feeds_sorted, node_feeds_count / 2)
  }
    |> option.or_else(fail @"median: empty list")
}

/// Returns list of nodes which are not outliers using interquartile range algorithm (IQR).
pub fn consensus_by_iqr(
  node_feeds: Pairs<NodeId, NodeFeed>,
  node_feeds_count: Int,
  iqr_fence_multiplier: Percent,
) -> List<NodeId> {
  if node_feeds_count < 4 {
    list.map(node_feeds, builtin.fst_pair)
  } else {
    let (lower_fence, upper_fence) =
      list.map(node_feeds, builtin.snd_pair)
        |> iqr_fences(node_feeds_count, iqr_fence_multiplier)

    list.filter_map(
      node_feeds,
      fn(p) {
        let id = builtin.fst_pair(p)
        let feed = builtin.snd_pair(p)

        if feed < lower_fence || feed > upper_fence {
          None
        } else {
          Some(id)
        }
      },
    )
  }
}

/// To ensure a more reliable outlier detection using IQR, it's advisable to have a sample size of at least 20-30 data points,
/// i.e. five points per quartile.
/// Naturally, minimum number of points is four, to have at least one element in earch quartile,
/// but beware that IQR could become useless for sample sizes of 4-10.
pub fn iqr_fences(
  node_feeds_sorted: List<NodeFeed>,
  node_feeds_count: Int,
  iqr_fence_multiplier: Percent,
) -> (NodeFeed, NodeFeed) {
  let mid_index = middle_index_between(0, node_feeds_count - 1)

  let q1 =
    middle_index_between(0, mid_index)
      |> list.at(node_feeds_sorted, _)
      |> option.or_else(fail @"empty q1")

  let q3_index =
    if node_feeds_count % 2 == 0 {
      middle_index_between(mid_index + 1, node_feeds_count - 1)
    } else {
      middle_index_between(mid_index + 1, node_feeds_count)
    }
  let q3 =
    list.at(node_feeds_sorted, q3_index)
      |> option.or_else(fail @"empty q3")

  let iqr = rational.from_int(q3 - q1)

  expect Some(multiplier) = rational.new(iqr_fence_multiplier, per_cent)
  let fence = rational.mul(iqr, multiplier) |> rational.round_even
  let lower_fence = q1 - fence
  let upper_fence = q3 + fence

  (lower_fence, upper_fence)
}

fn middle_index_between(left_index: Int, right_index: Int) -> Int {
  let size = right_index - left_index + 1
  let mid = ( size + 1 ) / 2 - 1

  mid + left_index
}
