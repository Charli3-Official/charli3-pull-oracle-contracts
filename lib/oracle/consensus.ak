use aiken/builtin
use aiken/collection/list
use aiken/math/rational
use aiken/option
use aiken/primitive/int
use ext/aiken/math/rational.{Percent, per_cent} as ext
use oracle/datum.{NodeFeed, NodeId, OracleFeed}

pub fn median(node_feeds: List<NodeFeed>) -> OracleFeed {
  let length = list.length(node_feeds)
  let sorted = list.sort(node_feeds, int.compare)

  if length % 2 == 0 {
    option.map2(
      list.at(sorted, length / 2),
      list.at(sorted, length / 2 - 1),
      fn(a, b) { ( a + b ) / 2 },
    )
  } else {
    list.at(sorted, length / 2)
  }
    |> option.or_else(fail @"median: empty list")
}

/// Returns list of nodes which are not outliers using interquartile range algorithm (IQR).
pub fn consensus_by_iqr(
  node_feeds: Pairs<NodeId, NodeFeed>,
  iqr_fence_multiplier: Percent,
) -> List<NodeId> {
  let length = list.length(node_feeds)
  if length < 4 {
    list.map(node_feeds, builtin.fst_pair)
  } else {
    let (lower_fence, upper_fence) =
      list.map(node_feeds, builtin.snd_pair) |> iqr_fences(iqr_fence_multiplier)

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
  node_feeds: List<NodeFeed>,
  iqr_fence_multiplier: Percent,
) -> (NodeFeed, NodeFeed) {
  let length = list.length(node_feeds)
  let sorted = list.sort(node_feeds, int.compare)

  let mid_index = middle_index_between(0, length - 1)

  let q1 =
    middle_index_between(0, mid_index)
      |> list.at(sorted, _)
      |> option.or_else(fail @"empty q1")

  let q3_index =
    if length % 2 == 0 {
      middle_index_between(mid_index + 1, length - 1)
    } else {
      middle_index_between(mid_index + 1, length)
    }
  let q3 =
    list.at(sorted, q3_index)
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
