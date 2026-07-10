//! Stable, persisted three-level projection for topology V3.
//!
//! Structural edges alone determine communities, folds, keys, bridges, and
//! coordinates. FDC codes are summarized only after that projection exists.

use crate::topology_analysis::{GraphTopology, GraphTopologyEdge, GraphTopologyNode};
use serde::Deserialize;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet, VecDeque};

const TARGET_FOLD_SIZE: usize = 192;
const MAX_FOLDS_PER_COMMUNITY: usize = 64;

#[derive(Debug, Clone)]
pub(crate) struct ProjectedNode {
    pub community_key: Option<String>,
    pub fold_key: Option<String>,
    pub x: f64,
    pub y: f64,
    pub z: f64,
    pub representative: bool,
}

#[derive(Debug, Clone)]
pub(crate) struct ProjectedCommunity {
    pub raw_id: i64,
    pub stable_key: String,
    pub size: usize,
    pub point: Point,
    pub fold_count: usize,
    pub representative_ids: Vec<String>,
    pub classification_purity: f64,
}

#[derive(Debug, Clone)]
pub(crate) struct ProjectedFold {
    pub stable_key: String,
    pub community_key: String,
    pub size: usize,
    pub point: Point,
    pub representative_ids: Vec<String>,
    pub dominant_udc_code: String,
}

#[derive(Debug, Clone)]
pub(crate) struct ProjectedBridge {
    pub level: String,
    pub source_key: String,
    pub target_key: String,
    pub edge_type: String,
    pub weight: f64,
    pub edge_count: usize,
}

#[derive(Debug, Clone)]
pub(crate) struct Projection {
    pub nodes_by_id: HashMap<String, ProjectedNode>,
    pub communities: Vec<ProjectedCommunity>,
    pub folds: Vec<ProjectedFold>,
    pub bridges: Vec<ProjectedBridge>,
}

#[derive(Debug, Clone, Copy, Deserialize)]
pub(crate) struct Point {
    pub x: f64,
    pub y: f64,
    pub z: f64,
}

impl Point {
    fn zero() -> Self {
        Self {
            x: 0.0,
            y: 0.0,
            z: 0.0,
        }
    }
    fn add(self, rhs: Self) -> Self {
        Self {
            x: self.x + rhs.x,
            y: self.y + rhs.y,
            z: self.z + rhs.z,
        }
    }
    fn scale(self, value: f64) -> Self {
        Self {
            x: self.x * value,
            y: self.y * value,
            z: self.z * value,
        }
    }
    fn bounded(self) -> Self {
        Self {
            x: self.x.clamp(-0.98, 0.98),
            y: self.y.clamp(-0.78, 0.78),
            z: self.z.clamp(-0.82, 0.82),
        }
    }
}

#[derive(Deserialize, Default)]
struct PreviousSnapshot {
    #[serde(default)]
    nodes: Vec<PreviousNode>,
    #[serde(default)]
    communities: Vec<PreviousAggregate>,
    #[serde(default)]
    folds: Vec<PreviousAggregate>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PreviousNode {
    id: String,
    #[serde(default)]
    community_key: Option<String>,
    #[serde(default)]
    fold_key: Option<String>,
    #[serde(default)]
    x: Option<f64>,
    #[serde(default)]
    y: Option<f64>,
    #[serde(default)]
    z: Option<f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PreviousAggregate {
    stable_key: String,
    #[serde(default)]
    x: Option<f64>,
    #[serde(default)]
    y: Option<f64>,
    #[serde(default)]
    z: Option<f64>,
}

#[derive(Clone)]
struct RawGroup {
    raw_key: String,
    members: Vec<String>,
}

#[derive(Debug, Clone, Eq, PartialEq, Ord, PartialOrd)]
struct BridgeKey {
    level: String,
    source: String,
    target: String,
    edge_type: String,
}

#[derive(Default, Clone)]
struct BridgeValue {
    weight: f64,
    count: usize,
    source_representative: Option<(String, f64)>,
    target_representative: Option<(String, f64)>,
}

pub(crate) fn project(topology: &GraphTopology, previous_json: Option<&str>) -> Projection {
    let previous = previous_json
        .and_then(|body| serde_json::from_str::<PreviousSnapshot>(body).ok())
        .unwrap_or_default();
    let previous_nodes: HashMap<&str, &PreviousNode> = previous
        .nodes
        .iter()
        .map(|node| (node.id.as_str(), node))
        .collect();

    let live: Vec<&GraphTopologyNode> = topology
        .nodes
        .iter()
        .filter(|node| node.community_id >= 0 && node.tombstoned_ts.is_none())
        .collect();
    let live_by_id: HashMap<&str, &GraphTopologyNode> =
        live.iter().map(|node| (node.id.as_str(), *node)).collect();
    let live_ids: HashSet<&str> = live_by_id.keys().copied().collect();
    let mut structural_edges: Vec<&GraphTopologyEdge> = topology
        .edges
        .iter()
        .filter(|edge| {
            edge.edge_type != "lattice"
                && edge.tombstoned_ts.is_none()
                && live_ids.contains(edge.source.as_str())
                && live_ids.contains(edge.target.as_str())
        })
        .collect();
    structural_edges.sort_by(|a, b| {
        a.source
            .cmp(&b.source)
            .then_with(|| a.target.cmp(&b.target))
            .then_with(|| a.edge_type.cmp(b.edge_type))
    });

    let mut adjacency: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    let mut weighted_adjacency: BTreeMap<String, BTreeMap<String, f64>> = BTreeMap::new();
    for edge in &structural_edges {
        if edge.source == edge.target {
            continue;
        }
        adjacency
            .entry(edge.source.clone())
            .or_default()
            .insert(edge.target.clone());
        adjacency
            .entry(edge.target.clone())
            .or_default()
            .insert(edge.source.clone());
        *weighted_adjacency
            .entry(edge.source.clone())
            .or_default()
            .entry(edge.target.clone())
            .or_default() += edge.weight;
        *weighted_adjacency
            .entry(edge.target.clone())
            .or_default()
            .entry(edge.source.clone())
            .or_default() += edge.weight;
    }

    let mut members_by_raw: BTreeMap<i64, Vec<&GraphTopologyNode>> = BTreeMap::new();
    for node in &live {
        members_by_raw
            .entry(node.community_id)
            .or_default()
            .push(*node);
    }
    for members in members_by_raw.values_mut() {
        members.sort_by(|a, b| a.id.cmp(&b.id));
    }
    let community_groups: Vec<RawGroup> = members_by_raw
        .iter()
        .map(|(raw, members)| RawGroup {
            raw_key: raw.to_string(),
            members: members.iter().map(|node| node.id.clone()).collect(),
        })
        .collect();
    let previous_community_by_member: HashMap<String, String> = previous
        .nodes
        .iter()
        .filter_map(|node| {
            node.community_key
                .as_ref()
                .filter(|key| !key.is_empty())
                .map(|key| (node.id.clone(), key.clone()))
        })
        .collect();
    let community_keys = stable_keys(&community_groups, &previous_community_by_member, "c");

    let mut fold_groups = Vec::new();
    for (raw, members) in &members_by_raw {
        for (index, ids) in partition_folds(members, &adjacency).into_iter().enumerate() {
            fold_groups.push(RawGroup {
                raw_key: format!("{raw}:{index}"),
                members: ids,
            });
        }
    }
    let previous_fold_by_member: HashMap<String, String> = previous
        .nodes
        .iter()
        .filter_map(|node| {
            node.fold_key
                .as_ref()
                .filter(|key| !key.is_empty())
                .map(|key| (node.id.clone(), key.clone()))
        })
        .collect();
    let fold_keys = stable_keys(&fold_groups, &previous_fold_by_member, "f");

    let mut community_key_by_node = HashMap::new();
    let mut fold_key_by_node = HashMap::new();
    for group in &community_groups {
        let stable = community_keys[&group.raw_key].clone();
        for id in &group.members {
            community_key_by_node.insert(id.clone(), stable.clone());
        }
    }
    for group in &fold_groups {
        let stable = fold_keys[&group.raw_key].clone();
        for id in &group.members {
            fold_key_by_node.insert(id.clone(), stable.clone());
        }
    }

    let centrality: HashMap<&str, f64> = topology
        .nodes
        .iter()
        .map(|node| (node.id.as_str(), node.centrality))
        .collect();
    let mut bridge_values: BTreeMap<BridgeKey, BridgeValue> = BTreeMap::new();
    for edge in &structural_edges {
        let Some(source_community) = community_key_by_node.get(&edge.source) else {
            continue;
        };
        let Some(target_community) = community_key_by_node.get(&edge.target) else {
            continue;
        };
        let Some(source_fold) = fold_key_by_node.get(&edge.source) else {
            continue;
        };
        let Some(target_fold) = fold_key_by_node.get(&edge.target) else {
            continue;
        };
        if source_community != target_community {
            accumulate_bridge(
                "community",
                source_community,
                target_community,
                edge,
                &centrality,
                &mut bridge_values,
            );
        }
        if source_fold != target_fold {
            accumulate_bridge(
                "fold",
                source_fold,
                target_fold,
                edge,
                &centrality,
                &mut bridge_values,
            );
        }
    }

    let previous_community_positions = previous_positions(&previous.communities);
    let previous_fold_positions = previous_positions(&previous.folds);
    let community_bridge_values: BTreeMap<BridgeKey, BridgeValue> = bridge_values
        .iter()
        .filter(|(key, _)| key.level == "community")
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect();
    let community_positions = aggregate_positions(
        community_groups
            .iter()
            .map(|group| community_keys[&group.raw_key].clone())
            .collect(),
        &previous_community_positions,
        &community_bridge_values,
        0.72,
        Point::zero(),
    );

    let mut representatives = BTreeSet::new();
    for value in bridge_values.values() {
        if let Some((id, _)) = &value.source_representative {
            representatives.insert(id.clone());
        }
        if let Some((id, _)) = &value.target_representative {
            representatives.insert(id.clone());
        }
    }

    let mut fold_positions = HashMap::new();
    for community_group in &community_groups {
        let community_key = community_keys[&community_group.raw_key].clone();
        let center = community_positions
            .get(&community_key)
            .copied()
            .unwrap_or_else(Point::zero);
        let prefix = format!("{}:", community_group.raw_key);
        let mut local_keys: Vec<String> = fold_groups
            .iter()
            .filter(|group| group.raw_key.starts_with(&prefix))
            .map(|group| fold_keys[&group.raw_key].clone())
            .collect();
        local_keys.sort();
        let key_set: HashSet<&str> = local_keys.iter().map(String::as_str).collect();
        let prior: HashMap<String, Point> = local_keys
            .iter()
            .filter_map(|key| {
                previous_fold_positions
                    .get(key)
                    .map(|point| (key.clone(), *point))
            })
            .collect();
        let local_bridges: BTreeMap<BridgeKey, BridgeValue> = bridge_values
            .iter()
            .filter(|(key, _)| {
                key.level == "fold"
                    && key_set.contains(key.source.as_str())
                    && key_set.contains(key.target.as_str())
            })
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect();
        fold_positions.extend(aggregate_positions(
            local_keys,
            &prior,
            &local_bridges,
            0.17,
            center,
        ));
    }
    let mut folds = Vec::new();
    let mut sorted_fold_groups = fold_groups.clone();
    sorted_fold_groups.sort_by_key(|group| fold_keys[&group.raw_key].clone());
    for group in &sorted_fold_groups {
        let fold_key = fold_keys[&group.raw_key].clone();
        let raw_community = group.raw_key.split(':').next().unwrap_or_default();
        let community_key = community_keys[raw_community].clone();
        let point = fold_positions
            .get(&fold_key)
            .copied()
            .unwrap_or_else(Point::zero);
        let top = top_members(&group.members, &centrality, 3);
        representatives.extend(top.iter().cloned());
        let codes: Vec<String> = group
            .members
            .iter()
            .filter_map(|id| {
                live_by_id
                    .get(id.as_str())
                    .and_then(|node| node.udc_code.clone())
            })
            .collect();
        folds.push(ProjectedFold {
            stable_key: fold_key,
            community_key,
            size: group.members.len(),
            point,
            representative_ids: top,
            dominant_udc_code: dominant_code(&codes),
        });
    }

    let mut communities = Vec::new();
    let mut sorted_community_groups = community_groups.clone();
    sorted_community_groups.sort_by_key(|group| community_keys[&group.raw_key].clone());
    for group in &sorted_community_groups {
        let stable_key = community_keys[&group.raw_key].clone();
        let point = community_positions
            .get(&stable_key)
            .copied()
            .unwrap_or_else(Point::zero);
        let top = top_members(&group.members, &centrality, 3);
        representatives.extend(top.iter().cloned());
        let codes: Vec<String> = group
            .members
            .iter()
            .filter_map(|id| {
                live_by_id
                    .get(id.as_str())
                    .and_then(|node| node.udc_code.clone())
            })
            .filter(|code| !code.is_empty() && code != "000")
            .collect();
        let mut counts = HashMap::new();
        for code in codes {
            *counts.entry(code).or_insert(0usize) += 1;
        }
        let dominant_count = counts.values().copied().max().unwrap_or(0);
        let fold_count = fold_groups
            .iter()
            .filter(|fold| fold.raw_key.starts_with(&format!("{}:", group.raw_key)))
            .count();
        communities.push(ProjectedCommunity {
            raw_id: group.raw_key.parse().unwrap_or(0),
            stable_key,
            size: group.members.len(),
            point,
            fold_count,
            representative_ids: top,
            classification_purity: if group.members.is_empty() {
                0.0
            } else {
                dominant_count as f64 / group.members.len() as f64
            },
        });
    }

    let mut live_positions = HashMap::new();
    for group in &sorted_fold_groups {
        let fold_key = &fold_keys[&group.raw_key];
        let Some(center) = fold_positions.get(fold_key).copied() else {
            continue;
        };
        let mut members = group.members.clone();
        members.sort();
        let member_set: HashSet<&str> = members.iter().map(String::as_str).collect();
        let spread = (0.025 + (members.len().max(1) as f64).sqrt() * 0.003).min(0.12);
        let mut positions = HashMap::new();
        let mut fixed = HashSet::new();
        for id in &members {
            if let Some(prior) = previous_nodes
                .get(id.as_str())
                .and_then(|node| previous_point(node))
            {
                positions.insert(id.clone(), prior);
                fixed.insert(id.clone());
            } else {
                positions.insert(
                    id.clone(),
                    center.add(hash_direction(id).scale(spread)).bounded(),
                );
            }
        }
        let anchors = positions.clone();
        let movable: Vec<&String> = members.iter().filter(|id| !fixed.contains(*id)).collect();
        for _ in 0..16 {
            let mut next = positions.clone();
            for &id in &movable {
                let Some(neighbors) = weighted_adjacency.get(id) else {
                    continue;
                };
                let usable: Vec<(Point, f64)> = neighbors
                    .iter()
                    .filter_map(|(neighbor, weight)| {
                        if !member_set.contains(neighbor.as_str()) {
                            return None;
                        }
                        positions
                            .get(neighbor)
                            .copied()
                            .map(|position| (position, weight.max(0.01)))
                    })
                    .collect();
                if !usable.is_empty() {
                    let total: f64 = usable.iter().map(|(_, weight)| weight).sum();
                    let average = usable
                        .into_iter()
                        .fold(Point::zero(), |sum, (position, weight)| {
                            sum.add(position.scale(weight / total))
                        });
                    next.insert(
                        id.clone(),
                        anchors[id].scale(0.58).add(average.scale(0.42)).bounded(),
                    );
                }
            }
            positions = next;
        }
        live_positions.extend(positions);
    }

    let mut nodes_by_id = HashMap::with_capacity(topology.nodes.len());
    for node in &topology.nodes {
        if let (Some(community_key), Some(fold_key), Some(point)) = (
            community_key_by_node.get(&node.id),
            fold_key_by_node.get(&node.id),
            live_positions.get(&node.id),
        ) {
            nodes_by_id.insert(
                node.id.clone(),
                ProjectedNode {
                    community_key: Some(community_key.clone()),
                    fold_key: Some(fold_key.clone()),
                    x: point.x,
                    y: point.y,
                    z: point.z,
                    representative: representatives.contains(&node.id),
                },
            );
        } else {
            let point = previous_nodes
                .get(node.id.as_str())
                .and_then(|node| previous_point(node))
                .unwrap_or_else(|| hash_direction(&node.id).scale(0.9).bounded());
            nodes_by_id.insert(
                node.id.clone(),
                ProjectedNode {
                    community_key: None,
                    fold_key: None,
                    x: point.x,
                    y: point.y,
                    z: point.z,
                    representative: false,
                },
            );
        }
    }

    let bridges = bridge_values
        .into_iter()
        .map(|(key, value)| ProjectedBridge {
            level: key.level,
            source_key: key.source,
            target_key: key.target,
            edge_type: key.edge_type,
            weight: value.weight,
            edge_count: value.count,
        })
        .collect();
    Projection {
        nodes_by_id,
        communities,
        folds,
        bridges,
    }
}

fn partition_folds(
    members: &[&GraphTopologyNode],
    adjacency: &BTreeMap<String, BTreeSet<String>>,
) -> Vec<Vec<String>> {
    let mut ids: Vec<String> = members.iter().map(|node| node.id.clone()).collect();
    ids.sort();
    if ids.len() <= TARGET_FOLD_SIZE {
        return if ids.is_empty() { vec![] } else { vec![ids] };
    }
    let desired = ((ids.len() as f64 / TARGET_FOLD_SIZE as f64).ceil() as usize)
        .clamp(1, MAX_FOLDS_PER_COMMUNITY);
    let member_set: HashSet<&str> = ids.iter().map(String::as_str).collect();
    let score: HashMap<&str, f64> = members
        .iter()
        .map(|node| (node.id.as_str(), node.centrality))
        .collect();
    let first = ids
        .iter()
        .max_by(|a, b| {
            score[a.as_str()]
                .total_cmp(&score[b.as_str()])
                .then_with(|| b.cmp(a))
        })
        .unwrap()
        .clone();
    let mut seeds = vec![first];
    while seeds.len() < desired {
        let distance = distances(&seeds, &member_set, adjacency);
        let next = ids
            .iter()
            .filter(|id| !seeds.contains(id))
            .max_by(|a, b| {
                let ad = distance.get(a.as_str()).copied().unwrap_or(usize::MAX);
                let bd = distance.get(b.as_str()).copied().unwrap_or(usize::MAX);
                ad.cmp(&bd)
                    .then_with(|| score[a.as_str()].total_cmp(&score[b.as_str()]))
                    .then_with(|| b.cmp(a))
            })
            .cloned();
        match next {
            Some(id) => seeds.push(id),
            None => break,
        }
    }
    seeds.sort();
    let mut owner: HashMap<String, String> = HashMap::new();
    let mut distance: HashMap<String, usize> = HashMap::new();
    let mut queue = VecDeque::new();
    for seed in &seeds {
        owner.insert(seed.clone(), seed.clone());
        distance.insert(seed.clone(), 0);
        queue.push_back(seed.clone());
    }
    while let Some(current) = queue.pop_front() {
        let next_distance = distance[&current] + 1;
        for neighbor in adjacency
            .get(&current)
            .into_iter()
            .flatten()
            .filter(|neighbor| member_set.contains(neighbor.as_str()))
        {
            let current_owner = owner[&current].clone();
            let should_take = match distance.get(neighbor) {
                None => true,
                Some(old) if next_distance < *old => true,
                Some(old) if next_distance == *old => current_owner < owner[neighbor],
                _ => false,
            };
            if should_take {
                distance.insert(neighbor.clone(), next_distance);
                owner.insert(neighbor.clone(), current_owner);
                queue.push_back(neighbor.clone());
            }
        }
    }
    for id in &ids {
        if !owner.contains_key(id) {
            owner.insert(
                id.clone(),
                seeds[(fnv1a(id) % seeds.len() as u64) as usize].clone(),
            );
        }
    }
    let mut groups: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for id in ids {
        groups.entry(owner[&id].clone()).or_default().push(id);
    }
    groups.into_values().collect()
}

fn distances(
    seeds: &[String],
    members: &HashSet<&str>,
    adjacency: &BTreeMap<String, BTreeSet<String>>,
) -> HashMap<String, usize> {
    let mut result = HashMap::new();
    let mut queue = VecDeque::new();
    let mut sorted = seeds.to_vec();
    sorted.sort();
    for seed in sorted {
        result.insert(seed.clone(), 0);
        queue.push_back(seed);
    }
    while let Some(current) = queue.pop_front() {
        let next = result[&current] + 1;
        for neighbor in adjacency
            .get(&current)
            .into_iter()
            .flatten()
            .filter(|neighbor| members.contains(neighbor.as_str()))
        {
            if !result.contains_key(neighbor) {
                result.insert(neighbor.clone(), next);
                queue.push_back(neighbor.clone());
            }
        }
    }
    result
}

fn stable_keys(
    groups: &[RawGroup],
    previous: &HashMap<String, String>,
    prefix: &str,
) -> HashMap<String, String> {
    let mut candidates = Vec::new();
    let mut previous_sizes: HashMap<&str, usize> = HashMap::new();
    for key in previous.values() {
        *previous_sizes.entry(key.as_str()).or_default() += 1;
    }
    for group in groups {
        let mut counts: BTreeMap<String, usize> = BTreeMap::new();
        for member in &group.members {
            if let Some(key) = previous.get(member) {
                *counts.entry(key.clone()).or_default() += 1;
            }
        }
        for (key, overlap) in counts {
            let larger_membership = group
                .members
                .len()
                .max(previous_sizes.get(key.as_str()).copied().unwrap_or(0));
            if overlap * 2 <= larger_membership {
                continue;
            }
            candidates.push((group.raw_key.clone(), key, overlap, group.members.len()));
        }
    }
    candidates.sort_by(|a, b| {
        b.2.cmp(&a.2)
            .then_with(|| {
                (b.2 as f64 / b.3.max(1) as f64).total_cmp(&(a.2 as f64 / a.3.max(1) as f64))
            })
            .then_with(|| a.1.cmp(&b.1))
            .then_with(|| a.0.cmp(&b.0))
    });
    let mut result = HashMap::new();
    let mut used = HashSet::new();
    for (raw, old, _, _) in candidates {
        if !result.contains_key(&raw) && used.insert(old.clone()) {
            result.insert(raw, old);
        }
    }
    for group in groups {
        result
            .entry(group.raw_key.clone())
            .or_insert_with(|| format!("{prefix}-{:x}", fnv1a(&group.members.join("\u{1}"))));
    }
    result
}

fn accumulate_bridge(
    level: &str,
    source: &str,
    target: &str,
    edge: &GraphTopologyEdge,
    centrality: &HashMap<&str, f64>,
    values: &mut BTreeMap<BridgeKey, BridgeValue>,
) {
    let (source_key, target_key, source_id, target_id) = if source < target {
        (source, target, edge.source.as_str(), edge.target.as_str())
    } else {
        (target, source, edge.target.as_str(), edge.source.as_str())
    };
    let key = BridgeKey {
        level: level.into(),
        source: source_key.into(),
        target: target_key.into(),
        edge_type: edge.edge_type.to_string(),
    };
    let value = values.entry(key).or_default();
    value.weight += edge.weight;
    value.count += 1;
    select_representative(
        &mut value.source_representative,
        source_id,
        *centrality.get(source_id).unwrap_or(&0.0),
    );
    select_representative(
        &mut value.target_representative,
        target_id,
        *centrality.get(target_id).unwrap_or(&0.0),
    );
}

fn select_representative(slot: &mut Option<(String, f64)>, id: &str, score: f64) {
    if slot.as_ref().map_or(true, |old| {
        score > old.1 || (score == old.1 && id < old.0.as_str())
    }) {
        *slot = Some((id.into(), score));
    }
}

fn aggregate_positions(
    keys: Vec<String>,
    previous: &HashMap<String, Point>,
    bridges: &BTreeMap<BridgeKey, BridgeValue>,
    radius: f64,
    fallback_center: Point,
) -> HashMap<String, Point> {
    let mut keys = keys;
    keys.sort();
    let mut positions = HashMap::new();
    for key in &keys {
        if let Some(old) = previous.get(key) {
            positions.insert(key.clone(), *old);
        }
    }
    for key in &keys {
        if positions.contains_key(key) {
            continue;
        }
        let neighbors: Vec<(Point, f64)> = bridges
            .iter()
            .filter_map(|(bridge, value)| {
                let other = if bridge.source == *key {
                    &bridge.target
                } else if bridge.target == *key {
                    &bridge.source
                } else {
                    return None;
                };
                positions
                    .get(other)
                    .copied()
                    .map(|point| (point, value.weight.max(0.01)))
            })
            .collect();
        let point = if neighbors.is_empty() {
            fallback_center
                .add(hash_direction(key).scale(radius))
                .bounded()
        } else {
            let total: f64 = neighbors.iter().map(|(_, weight)| weight).sum();
            neighbors
                .into_iter()
                .fold(Point::zero(), |sum, (point, weight)| {
                    sum.add(point.scale(weight / total))
                })
                .add(hash_direction(key).scale(radius * 0.28))
                .bounded()
        };
        positions.insert(key.clone(), point);
    }
    if previous.is_empty() {
        let anchors = positions.clone();
        for _ in 0..12 {
            let mut next = positions.clone();
            for key in &keys {
                let neighbors: Vec<(Point, f64)> = bridges
                    .iter()
                    .filter_map(|(bridge, value)| {
                        let other = if bridge.source == *key {
                            &bridge.target
                        } else if bridge.target == *key {
                            &bridge.source
                        } else {
                            return None;
                        };
                        positions
                            .get(other)
                            .copied()
                            .map(|point| (point, value.weight.max(0.01)))
                    })
                    .collect();
                if neighbors.is_empty() {
                    continue;
                }
                let total: f64 = neighbors.iter().map(|(_, weight)| weight).sum();
                let average = neighbors
                    .into_iter()
                    .fold(Point::zero(), |sum, (point, weight)| {
                        sum.add(point.scale(weight / total))
                    });
                next.insert(
                    key.clone(),
                    anchors[key].scale(0.76).add(average.scale(0.24)).bounded(),
                );
            }
            positions = next;
        }
    }
    positions
}

fn previous_positions(aggregates: &[PreviousAggregate]) -> HashMap<String, Point> {
    aggregates
        .iter()
        .filter_map(|aggregate| {
            Some((
                aggregate.stable_key.clone(),
                Point {
                    x: aggregate.x?,
                    y: aggregate.y?,
                    z: aggregate.z?,
                },
            ))
        })
        .collect()
}

fn previous_point(node: &PreviousNode) -> Option<Point> {
    Some(Point {
        x: node.x?,
        y: node.y?,
        z: node.z?,
    })
}

fn top_members(members: &[String], centrality: &HashMap<&str, f64>, count: usize) -> Vec<String> {
    let mut members = members.to_vec();
    members.sort_by(|a, b| {
        centrality
            .get(b.as_str())
            .unwrap_or(&0.0)
            .total_cmp(centrality.get(a.as_str()).unwrap_or(&0.0))
            .then_with(|| a.cmp(b))
    });
    members.truncate(count);
    members
}

fn dominant_code(codes: &[String]) -> String {
    let mut counts: BTreeMap<&str, usize> = BTreeMap::new();
    for code in codes
        .iter()
        .filter(|code| !code.is_empty() && code.as_str() != "000")
    {
        *counts.entry(code).or_default() += 1;
    }
    counts
        .into_iter()
        .max_by(|a, b| a.1.cmp(&b.1).then_with(|| b.0.cmp(a.0)))
        .map(|(code, _)| code.to_string())
        .unwrap_or_default()
}

fn hash_direction(value: &str) -> Point {
    let unit = |salt: &str| (fnv1a(&format!("{value}{salt}")) & 0xffff) as f64 / 32_767.5 - 1.0;
    let (mut x, mut y, mut z) = (unit("x"), unit("y"), unit("z"));
    let length = (x * x + y * y + z * z).sqrt();
    if length < 0.000_001 {
        x = 1.0;
        y = 0.0;
        z = 0.0;
    } else {
        x /= length;
        y /= length;
        z /= length;
    }
    Point {
        x: x * 0.98,
        y: y * 0.76,
        z: z * 0.80,
    }
}

fn fnv1a(value: &str) -> u64 {
    let mut hash = 0xcbf2_9ce4_8422_2325u64;
    for byte in value.as_bytes() {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::topology_analysis::{GraphTopologyCommunity, GraphTopologyEdge, GraphTopologyNode};

    fn node(id: &str, community_id: i64, code: Option<&str>) -> GraphTopologyNode {
        GraphTopologyNode {
            id: id.into(),
            community_id,
            centrality: if id == "a" { 1.0 } else { 0.5 },
            last_active_ts: None,
            created_ts: Some("2026-01-01T00:00:00Z".into()),
            tombstoned_ts: None,
            udc_code: code.map(str::to_owned),
        }
    }

    fn edge(source: &str, target: &str, edge_type: &'static str) -> GraphTopologyEdge {
        GraphTopologyEdge {
            source: source.into(),
            target: target.into(),
            edge_type,
            weight: if edge_type == "tunnel" { 1.0 } else { 0.3 },
            created_ts: None,
            tombstoned_ts: None,
        }
    }

    #[test]
    fn fdc_does_not_change_keys_positions_or_bridges() {
        let make = |codes: [Option<&str>; 3]| GraphTopology {
            nodes: vec![
                node("a", 0, codes[0]),
                node("b", 0, codes[1]),
                node("c", 1, codes[2]),
            ],
            edges: vec![
                edge("a", "b", "tunnel"),
                edge("b", "c", "kgFact"),
                edge("a", "c", "lattice"),
            ],
            community_count: 2,
            communities: vec![
                GraphTopologyCommunity {
                    id: 0,
                    size: 2,
                    dominant_udc_code: String::new(),
                },
                GraphTopologyCommunity {
                    id: 1,
                    size: 1,
                    dominant_udc_code: String::new(),
                },
            ],
        };
        let first = project(&make([Some("362.4"), Some("362.4"), Some("900")]), None);
        let second = project(&make([Some("001"), Some("700"), None]), None);
        assert_eq!(
            first
                .communities
                .iter()
                .map(|c| &c.stable_key)
                .collect::<Vec<_>>(),
            second
                .communities
                .iter()
                .map(|c| &c.stable_key)
                .collect::<Vec<_>>()
        );
        assert_eq!(first.nodes_by_id["a"].x, second.nodes_by_id["a"].x);
        assert!(first
            .bridges
            .iter()
            .all(|bridge| bridge.edge_type == "kgFact"));
    }

    #[test]
    fn local_coordinates_respond_to_structural_relationships() {
        let make = |edges| GraphTopology {
            nodes: vec![node("a", 0, None), node("b", 0, None), node("c", 0, None)],
            edges,
            community_count: 1,
            communities: vec![GraphTopologyCommunity {
                id: 0,
                size: 3,
                dominant_udc_code: String::new(),
            }],
        };
        let first = project(&make(vec![edge("a", "b", "tunnel")]), None);
        let second = project(&make(vec![edge("b", "c", "tunnel")]), None);
        assert_eq!(first.nodes_by_id["a"].x, -0.4473993965904576);
        assert_eq!(first.nodes_by_id["a"].y, -0.2903365191220521);
        assert_eq!(first.nodes_by_id["b"].x, -0.44710111746239545);
        assert_eq!(first.nodes_by_id["b"].y, -0.2904329670558848);
        assert_ne!(first.nodes_by_id["a"].x, second.nodes_by_id["a"].x);
        assert_ne!(first.nodes_by_id["b"].y, second.nodes_by_id["b"].y);
    }

    #[test]
    fn overlap_preserves_keys_and_coordinates_after_raw_label_change() {
        let original = GraphTopology {
            nodes: vec![node("a", 0, None), node("b", 0, None)],
            edges: vec![edge("a", "b", "tunnel")],
            community_count: 1,
            communities: vec![GraphTopologyCommunity {
                id: 0,
                size: 2,
                dominant_udc_code: String::new(),
            }],
        };
        let first = project(&original, None);
        let community = &first.communities[0];
        let fold = &first.folds[0];
        assert_eq!(community.stable_key, "c-e5d6bb19042a894f");
        assert_eq!(fold.stable_key, "f-e5d6bb19042a894f");
        let previous_nodes: Vec<_> = first
            .nodes_by_id
            .iter()
            .map(|(id, node)| {
                serde_json::json!({
                    "id": id, "communityKey": node.community_key, "foldKey": node.fold_key,
                    "x": node.x, "y": node.y, "z": node.z
                })
            })
            .collect();
        let previous = serde_json::json!({
            "nodes": previous_nodes,
            "communities": [{"stableKey": community.stable_key, "x": community.point.x,
                               "y": community.point.y, "z": community.point.z}],
            "folds": [{"stableKey": fold.stable_key, "x": fold.point.x,
                        "y": fold.point.y, "z": fold.point.z}]
        })
        .to_string();
        let grown = GraphTopology {
            nodes: vec![node("a", 9, None), node("b", 9, None), node("new", 9, None)],
            edges: vec![edge("a", "b", "tunnel"), edge("b", "new", "tunnel")],
            community_count: 1,
            communities: vec![GraphTopologyCommunity {
                id: 9,
                size: 3,
                dominant_udc_code: String::new(),
            }],
        };
        let second = project(&grown, Some(&previous));
        assert_eq!(second.communities[0].stable_key, community.stable_key);
        assert_eq!(second.folds[0].stable_key, fold.stable_key);
        assert_eq!(second.nodes_by_id["a"].x, first.nodes_by_id["a"].x);
    }

    #[test]
    fn minor_overlap_does_not_reuse_replaced_identity() {
        let previous = serde_json::json!({
            "nodes": [
                {"id":"a","communityKey":"c-old","foldKey":"f-old","x":0.1,"y":0.2,"z":0.3},
                {"id":"b","communityKey":"c-old","foldKey":"f-old","x":0.2,"y":0.2,"z":0.3},
                {"id":"c","communityKey":"c-old","foldKey":"f-old","x":0.3,"y":0.2,"z":0.3}
            ],
            "communities": [{"stableKey":"c-old","x":0.2,"y":0.2,"z":0.3}],
            "folds": [{"stableKey":"f-old","x":0.2,"y":0.2,"z":0.3}]
        })
        .to_string();
        let topology = GraphTopology {
            nodes: vec![
                node("a", 9, None),
                node("new-1", 9, None),
                node("new-2", 9, None),
                node("new-3", 9, None),
            ],
            edges: vec![
                edge("a", "new-1", "tunnel"),
                edge("new-1", "new-2", "tunnel"),
                edge("new-2", "new-3", "tunnel"),
            ],
            community_count: 1,
            communities: vec![GraphTopologyCommunity {
                id: 9,
                size: 4,
                dominant_udc_code: String::new(),
            }],
        };
        let projected = project(&topology, Some(&previous));
        assert_ne!(projected.communities[0].stable_key, "c-old");
        assert_ne!(projected.folds[0].stable_key, "f-old");
    }

    #[test]
    fn large_community_splits_into_bounded_folds() {
        let nodes: Vec<_> = (0..400)
            .map(|i| node(&format!("n{i:03}"), 0, None))
            .collect();
        let edges: Vec<_> = (1..400)
            .map(|i| edge(&format!("n{:03}", i - 1), &format!("n{i:03}"), "tunnel"))
            .collect();
        let topology = GraphTopology {
            nodes,
            edges,
            community_count: 1,
            communities: vec![GraphTopologyCommunity {
                id: 0,
                size: 400,
                dominant_udc_code: String::new(),
            }],
        };
        let projected = project(&topology, None);
        assert_eq!(projected.folds.len(), 3);
        assert_eq!(
            projected.folds.iter().map(|fold| fold.size).sum::<usize>(),
            400
        );
        assert_eq!(
            projected
                .nodes_by_id
                .values()
                .filter_map(|node| node.fold_key.as_ref())
                .collect::<HashSet<_>>()
                .len(),
            3
        );
    }
}
