//! Typed v2 knowledge-graph and journal operations.
//!
//! This unregistered service calls public GeniusLocusKit/LocusKit verbs.  It
//! never invokes the v1 dispatcher or adapts a text/JSON response.

use std::{collections::{BTreeSet, HashSet}, sync::{Arc, Mutex}};

use genius_locus_kit::{EstateCoordinator, EstateHandle};
use locus_kit::{adjectives::AdjectiveSensitivity, kg_fact::{KGFact, KGFactOrigin}, tunnel::Tunnel, tunnel_operational::{TunnelKind, TunnelLifecycle}};
use uuid::Uuid;

use crate::jsonrpc::JsonValue;
use super::codec::{optional_integer, optional_string, optional_uuid, required_string, required_uuid, strict_object, V2DecodeResult, V2InvalidArgument};

pub const CONNECTION_SEARCH_TOOL: &str = "moot_connection_search";
pub const CONNECTION_MAP_TOOL: &str = "moot_connection_map";
pub const FILE_FACT_TOOL: &str = "moot_file_fact";
pub const FACT_SEARCH_TOOL: &str = "moot_fact_search";
pub const RETIRE_FACT_TOOL: &str = "moot_retire_fact";
pub const FACT_TIMELINE_TOOL: &str = "moot_fact_timeline";
pub const WRITE_JOURNAL_TOOL: &str = "moot_write_journal";
pub const READ_JOURNAL_TOOL: &str = "moot_read_journal";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum V2KnowledgeJournalOperation { ConnectionSearch, ConnectionMap, FileFact, FactSearch, RetireFact, FactTimeline, WriteJournal, ReadJournal }
impl V2KnowledgeJournalOperation {
    pub const fn tool_name(self) -> &'static str { match self {
        Self::ConnectionSearch => CONNECTION_SEARCH_TOOL, Self::ConnectionMap => CONNECTION_MAP_TOOL,
        Self::FileFact => FILE_FACT_TOOL, Self::FactSearch => FACT_SEARCH_TOOL, Self::RetireFact => RETIRE_FACT_TOOL,
        Self::FactTimeline => FACT_TIMELINE_TOOL, Self::WriteJournal => WRITE_JOURNAL_TOOL, Self::ReadJournal => READ_JOURNAL_TOOL,
    }}
}

/// Selected-surface authority output.  Source visibility is represented only
/// by the supplied ceiling; no caller-provided estate ID grants access.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2KnowledgeJournalAdmission {
    pub estate_id: Uuid,
    pub estate_handle: EstateHandle,
    pub caller_binding: String,
    pub maximum_sensitivity: AdjectiveSensitivity,
    pub now_millis: i64,
}
pub trait V2KnowledgeJournalAuthority: Send + Sync {
    fn admit(&self, operation: V2KnowledgeJournalOperation, requested_estate_id: Option<Uuid>) -> Result<V2KnowledgeJournalAdmission, ()>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)] pub enum V2ConnectionDirection { Outgoing, Incoming, Both }
#[derive(Debug, Clone, PartialEq, Eq)] pub struct V2ConnectionSearchRequest { pub memory_id: Uuid, pub relationship: Option<String>, pub direction: V2ConnectionDirection, pub limit: usize, pub estate_id: Option<Uuid> }
#[derive(Debug, Clone, PartialEq, Eq)] pub struct V2ConnectionMapRequest { pub memory_id: Uuid, pub depth: usize, pub limit: usize, pub estate_id: Option<Uuid> }
#[derive(Debug, Clone, PartialEq, Eq)] pub struct V2FileFactRequest { pub subject: String, pub predicate: String, pub object: String, pub source_memory_id: Option<Uuid>, pub event_time_millis: Option<i64>, pub estate_id: Option<Uuid> }
#[derive(Debug, Clone, PartialEq, Eq)] pub struct V2FactSearchRequest { pub query: Option<String>, pub subject: Option<String>, pub predicate: Option<String>, pub object: Option<String>, pub limit: usize, pub estate_id: Option<Uuid> }
#[derive(Debug, Clone, PartialEq, Eq)] pub struct V2RetireFactRequest { pub fact_id: Uuid, pub reason: Option<String>, pub estate_id: Option<Uuid> }
#[derive(Debug, Clone, PartialEq, Eq)] pub struct V2FactTimelineRequest { pub subject: String, pub predicate: Option<String>, pub limit: usize, pub estate_id: Option<Uuid> }
#[derive(Debug, Clone, PartialEq, Eq)] pub struct V2WriteJournalRequest { pub content: String, pub entry_time_millis: Option<i64>, pub tags: Option<String>, pub estate_id: Option<Uuid> }
#[derive(Debug, Clone, PartialEq, Eq)] pub struct V2ReadJournalRequest { pub limit: usize, pub before_millis: Option<i64>, pub after_millis: Option<i64>, pub estate_id: Option<Uuid> }

impl V2ConnectionSearchRequest { pub fn decode(v: &JsonValue) -> V2DecodeResult<Self> { let o = strict_object(v, ["memory_id", "relationship", "direction", "limit", "estate_id"])?; Ok(Self { memory_id: required_uuid(o,"memory_id")?, relationship: optional_nonempty(o,"relationship")?, direction: match optional_string(o,"direction")? { None|Some("both")=>V2ConnectionDirection::Both, Some("outgoing")=>V2ConnectionDirection::Outgoing, Some("incoming")=>V2ConnectionDirection::Incoming, _=>return Err(V2InvalidArgument::new("$.direction","must be outgoing, incoming, or both")) }, limit: bounded(o,"limit",50,500)?, estate_id: optional_uuid(o,"estate_id")? }) } }
impl V2ConnectionMapRequest { pub fn decode(v: &JsonValue) -> V2DecodeResult<Self> { let o = strict_object(v,["memory_id","depth","limit","estate_id"])?; Ok(Self { memory_id: required_uuid(o,"memory_id")?, depth: bounded(o,"depth",1,50)?, limit: bounded(o,"limit",50,500)?, estate_id: optional_uuid(o,"estate_id")? }) } }
impl V2FileFactRequest { pub fn decode(v: &JsonValue) -> V2DecodeResult<Self> { let o = strict_object(v,["subject","predicate","object","source_memory_id","event_time","estate_id"])?; let subject=nonempty(required_string(o,"subject")?,"subject")?; if subject.chars().count()>120 { return Err(V2InvalidArgument::new("$.subject","must contain at most 120 characters")); } Ok(Self { subject, predicate: nonempty(required_string(o,"predicate")?,"predicate")?, object: nonempty(required_string(o,"object")?,"object")?, source_memory_id: optional_uuid(o,"source_memory_id")?, event_time_millis: optional_date(o,"event_time")?, estate_id: optional_uuid(o,"estate_id")? }) } }
impl V2FactSearchRequest { pub fn decode(v: &JsonValue) -> V2DecodeResult<Self> { let o = strict_object(v,["query","subject","predicate","object","limit","estate_id"])?; Ok(Self { query:optional_nonempty(o,"query")?, subject:optional_nonempty(o,"subject")?, predicate:optional_nonempty(o,"predicate")?, object:optional_nonempty(o,"object")?, limit:bounded(o,"limit",100,500)?, estate_id:optional_uuid(o,"estate_id")? }) } }
impl V2RetireFactRequest { pub fn decode(v: &JsonValue) -> V2DecodeResult<Self> { let o=strict_object(v,["fact_id","reason","estate_id"])?; Ok(Self { fact_id:required_uuid(o,"fact_id")?, reason:optional_nonempty(o,"reason")?, estate_id:optional_uuid(o,"estate_id")? }) } }
impl V2FactTimelineRequest { pub fn decode(v: &JsonValue) -> V2DecodeResult<Self> { let o=strict_object(v,["subject","predicate","limit","estate_id"])?; Ok(Self { subject:nonempty(required_string(o,"subject")?,"subject")?, predicate:optional_nonempty(o,"predicate")?, limit:bounded(o,"limit",200,500)?, estate_id:optional_uuid(o,"estate_id")? }) } }
impl V2WriteJournalRequest { pub fn decode(v: &JsonValue) -> V2DecodeResult<Self> { let o=strict_object(v,["content","entry_time","tags","estate_id"])?; Ok(Self { content:nonempty(required_string(o,"content")?,"content")?, entry_time_millis:optional_date(o,"entry_time")?, tags:optional_nonempty(o,"tags")?, estate_id:optional_uuid(o,"estate_id")? }) } }
impl V2ReadJournalRequest { pub fn decode(v: &JsonValue) -> V2DecodeResult<Self> { let o=strict_object(v,["limit","before","after","estate_id"])?; let before=optional_date(o,"before")?; let after=optional_date(o,"after")?; if matches!((after,before),(Some(a),Some(b)) if a>=b) { return Err(V2InvalidArgument::new("$.after","must be earlier than $.before")); } Ok(Self { limit:bounded(o,"limit",10,500)?, before_millis:before, after_millis:after, estate_id:optional_uuid(o,"estate_id")? }) } }

/// Below one is a SYNTAX ERROR and above the ceiling CLAMPS, matching the
/// Swift port and the shared limit funnel the older surface used.
///
/// The halves are deliberately asymmetric. A zero or negative limit is
/// meaningless and, unchecked, reaches SQLite as `LIMIT -1` — every row — so
/// it is refused. An over-large limit is a caller asking for more than the
/// surface gives, which the ceiling already answers; refusing it hands nothing
/// to a caller who asked for ten thousand instead of handing back the maximum.
fn bounded(o: &std::collections::BTreeMap<String,JsonValue>, key:&str, default:usize, maximum:usize)->V2DecodeResult<usize>{ match optional_integer(o,key)? { None=>Ok(default), Some(n) if n>=1 =>Ok((n as usize).min(maximum)), _=>Err(V2InvalidArgument::new(format!("$.{key}"),"must be at least 1")) } }
fn nonempty(v:&str,key:&str)->V2DecodeResult<String>{ if v.trim().is_empty(){Err(V2InvalidArgument::new(format!("$.{key}"),"must not be empty"))}else{Ok(v.to_owned())} }
fn optional_nonempty(o:&std::collections::BTreeMap<String,JsonValue>,key:&str)->V2DecodeResult<Option<String>>{ optional_string(o,key)?.map(|v|nonempty(v,key)).transpose() }
fn optional_date(o:&std::collections::BTreeMap<String,JsonValue>,key:&str)->V2DecodeResult<Option<i64>>{ optional_string(o,key)?.map(|v|parse_rfc3339(v,key)).transpose() }

/// Strict UTC/offset RFC-3339 parser.  The lower kits use epoch milliseconds;
/// this keeps date conversion at the typed boundary and never uses wall clock.
/// Canonical camelCase wire representation of a TunnelKind value.
///
/// `format!("{:?}", kind)` on a PascalCase Rust enum produces `"References"`,
/// `"DerivesFrom"` etc. — which is wrong. Swift emits camelCase via
/// `String(describing:)` on camelCase enum cases (e.g. `.derivesFrom`).
/// This function replicates the Swift wire output without relying on Debug.
fn tunnel_kind_wire(kind: TunnelKind) -> String {
    match kind {
        TunnelKind::Supersedes  => "supersedes".to_owned(),
        TunnelKind::References  => "references".to_owned(),
        TunnelKind::Blocks      => "blocks".to_owned(),
        TunnelKind::Validates   => "validates".to_owned(),
        TunnelKind::Contradicts => "contradicts".to_owned(),
        TunnelKind::DerivesFrom => "derivesFrom".to_owned(),
        TunnelKind::Covers      => "covers".to_owned(),
        TunnelKind::Elaborates  => "elaborates".to_owned(),
        TunnelKind::RespondsTo  => "respondsTo".to_owned(),
        TunnelKind::Parent      => "parent".to_owned(),
    }
}

fn parse_rfc3339(value:&str,key:&str)->V2DecodeResult<i64>{
    let invalid=||V2InvalidArgument::new(format!("$.{key}"),"must be an ISO-8601 date-time");
    let (date,time)=value.split_once('T').ok_or_else(invalid)?;
    let mut d=date.split('-'); let y:i64=d.next().ok_or_else(invalid)?.parse().map_err(|_|invalid())?; let m:i64=d.next().ok_or_else(invalid)?.parse().map_err(|_|invalid())?; let day:i64=d.next().ok_or_else(invalid)?.parse().map_err(|_|invalid())?;
    let leap=(y%4==0&&y%100!=0)||y%400==0;
    let max_day=match m{1|3|5|7|8|10|12=>31,4|6|9|11=>30,2 if leap=>29,2=>28,_=>return Err(invalid())};
    if d.next().is_some()||day<1||day>max_day{return Err(invalid());}
    let (clock,offset)=if let Some(t)=time.strip_suffix('Z'){(t,0)}else{let index=time.char_indices().skip(8).find_map(|(i,c)|matches!(c,'+'|'-').then_some(i)).ok_or_else(invalid)?; let (t,z)=time.split_at(index); let sign=if z.starts_with('+'){1}else{-1}; let (oh,om)=z[1..].split_once(':').ok_or_else(invalid)?; let h:i64=oh.parse().map_err(|_|invalid())?; let mm:i64=om.parse().map_err(|_|invalid())?; if h>23||mm>59{return Err(invalid());}(t,sign*(h*3600+mm*60))};
    let mut c=clock.split(':'); let hour:i64=c.next().ok_or_else(invalid)?.parse().map_err(|_|invalid())?; let minute:i64=c.next().ok_or_else(invalid)?.parse().map_err(|_|invalid())?; let second_part=c.next().ok_or_else(invalid)?; if c.next().is_some()||hour>23||minute>59{return Err(invalid());} let (second,fraction)=second_part.split_once('.').unwrap_or((second_part,"")); let second:i64=second.parse().map_err(|_|invalid())?; if second>59||fraction.len()>9||!fraction.bytes().all(|b|b.is_ascii_digit()){return Err(invalid());} let millis=if fraction.is_empty(){0}else{let mut digits=fraction.chars().take(3).collect::<String>();while digits.len()<3{digits.push('0');}digits.parse().map_err(|_|invalid())?};
    let y=y-(m<=2) as i64; let era=if y>=0{y}else{y-399}/400; let yoe=y-era*400; let mp=m+if m>2{-3}else{9}; let doy=(153*mp+2)/5+day-1; let doe=yoe*365+yoe/4-yoe/100+doy; let days=era*146097+doe-719468;
    Ok(((days*86400+hour*3600+minute*60+second-offset)*1000)+millis)
}

/// Source-faithful public rows. `None` is deliberate: KG facts may be
/// unanchored and tunnels may be room-level.  Render wiring must preserve it
/// rather than fabricate a UUID merely to satisfy a narrower row schema.
#[derive(Debug,Clone,PartialEq,Eq)] pub struct V2KnowledgeFact { pub fact_id:Uuid,pub subject:String,pub predicate:String,pub object:String,pub source_memory_id:Option<Uuid>,pub event_time_millis:i64,pub state:String }
#[derive(Debug,Clone,PartialEq,Eq)] pub struct V2KnowledgeTunnel {
    pub tunnel_id:Uuid,
    pub from_id:Option<Uuid>,
    pub to_id:Option<Uuid>,
    pub kind:String,
    /// Where this edge sits on the review ladder: `active`, `proposed`,
    /// `superseded` or `withdrawn`.  Dreaming and the contradiction hunt file
    /// `.proposed` edges on a timer, so a caller without this cannot tell a
    /// machine's guess from a user-confirmed link.
    pub lifecycle:String,
}
#[derive(Debug,Clone,PartialEq,Eq)] pub struct V2JournalEntry { pub agent_name:String,pub entry:String,pub written_at_millis:i64 }
#[derive(Debug,Clone,PartialEq,Eq)] pub enum V2KnowledgeJournalResult { Tunnels(Vec<V2KnowledgeTunnel>), Fact(V2KnowledgeFact), Facts(Vec<V2KnowledgeFact>), Retired{fact_id:Uuid}, JournalEntry(V2JournalEntry), JournalEntries(Vec<V2JournalEntry>) }
#[derive(Debug,Clone,Copy,PartialEq,Eq)] pub enum V2KnowledgeJournalError { Unavailable }

pub trait V2KnowledgeJournalLower: Send+Sync {
    fn connection_search(&self, admission:&V2KnowledgeJournalAdmission, request:&V2ConnectionSearchRequest)->Result<Vec<V2KnowledgeTunnel>,()>;
    fn connection_map(&self, admission:&V2KnowledgeJournalAdmission, request:&V2ConnectionMapRequest)->Result<Vec<V2KnowledgeTunnel>,()>;
    fn file_fact(&self, admission:&V2KnowledgeJournalAdmission, request:&V2FileFactRequest)->Result<V2KnowledgeFact,()>;
    fn fact_search(&self, admission:&V2KnowledgeJournalAdmission, request:&V2FactSearchRequest)->Result<Vec<V2KnowledgeFact>,()>;
    fn retire_fact(&self, admission:&V2KnowledgeJournalAdmission, request:&V2RetireFactRequest)->Result<(),()>;
    fn fact_timeline(&self, admission:&V2KnowledgeJournalAdmission, request:&V2FactTimelineRequest)->Result<Vec<V2KnowledgeFact>,()>;
    fn write_journal(&self, admission:&V2KnowledgeJournalAdmission, request:&V2WriteJournalRequest)->Result<V2JournalEntry,()>;
    fn read_journal(&self, admission:&V2KnowledgeJournalAdmission, request:&V2ReadJournalRequest)->Result<Vec<V2JournalEntry>,()>;
}
pub struct V2KnowledgeJournalService<A,L>{authority:A,lower:L} impl<A,L> V2KnowledgeJournalService<A,L>{pub fn new(authority:A,lower:L)->Self{Self{authority,lower}}}
impl<A:V2KnowledgeJournalAuthority,L:V2KnowledgeJournalLower> V2KnowledgeJournalService<A,L>{
    fn admit(&self,op:V2KnowledgeJournalOperation,estate:Option<Uuid>)->Result<V2KnowledgeJournalAdmission,V2KnowledgeJournalError>{self.authority.admit(op,estate).map_err(|_|V2KnowledgeJournalError::Unavailable)}
    pub fn connection_search(&self,r:V2ConnectionSearchRequest)->Result<V2KnowledgeJournalResult,V2KnowledgeJournalError>{let a=self.admit(V2KnowledgeJournalOperation::ConnectionSearch,r.estate_id)?;self.lower.connection_search(&a,&r).map(V2KnowledgeJournalResult::Tunnels).map_err(|_|V2KnowledgeJournalError::Unavailable)}
    pub fn connection_map(&self,r:V2ConnectionMapRequest)->Result<V2KnowledgeJournalResult,V2KnowledgeJournalError>{let a=self.admit(V2KnowledgeJournalOperation::ConnectionMap,r.estate_id)?;self.lower.connection_map(&a,&r).map(V2KnowledgeJournalResult::Tunnels).map_err(|_|V2KnowledgeJournalError::Unavailable)}
    pub fn file_fact(&self,r:V2FileFactRequest)->Result<V2KnowledgeJournalResult,V2KnowledgeJournalError>{let a=self.admit(V2KnowledgeJournalOperation::FileFact,r.estate_id)?;self.lower.file_fact(&a,&r).map(V2KnowledgeJournalResult::Fact).map_err(|_|V2KnowledgeJournalError::Unavailable)}
    pub fn fact_search(&self,r:V2FactSearchRequest)->Result<V2KnowledgeJournalResult,V2KnowledgeJournalError>{let a=self.admit(V2KnowledgeJournalOperation::FactSearch,r.estate_id)?;self.lower.fact_search(&a,&r).map(V2KnowledgeJournalResult::Facts).map_err(|_|V2KnowledgeJournalError::Unavailable)}
    pub fn retire_fact(&self,r:V2RetireFactRequest)->Result<V2KnowledgeJournalResult,V2KnowledgeJournalError>{let a=self.admit(V2KnowledgeJournalOperation::RetireFact,r.estate_id)?;self.lower.retire_fact(&a,&r).map(|_|V2KnowledgeJournalResult::Retired{fact_id:r.fact_id}).map_err(|_|V2KnowledgeJournalError::Unavailable)}
    pub fn fact_timeline(&self,r:V2FactTimelineRequest)->Result<V2KnowledgeJournalResult,V2KnowledgeJournalError>{let a=self.admit(V2KnowledgeJournalOperation::FactTimeline,r.estate_id)?;self.lower.fact_timeline(&a,&r).map(V2KnowledgeJournalResult::Facts).map_err(|_|V2KnowledgeJournalError::Unavailable)}
    pub fn write_journal(&self,r:V2WriteJournalRequest)->Result<V2KnowledgeJournalResult,V2KnowledgeJournalError>{let a=self.admit(V2KnowledgeJournalOperation::WriteJournal,r.estate_id)?;self.lower.write_journal(&a,&r).map(V2KnowledgeJournalResult::JournalEntry).map_err(|_|V2KnowledgeJournalError::Unavailable)}
    pub fn read_journal(&self,r:V2ReadJournalRequest)->Result<V2KnowledgeJournalResult,V2KnowledgeJournalError>{let a=self.admit(V2KnowledgeJournalOperation::ReadJournal,r.estate_id)?;self.lower.read_journal(&a,&r).map(V2KnowledgeJournalResult::JournalEntries).map_err(|_|V2KnowledgeJournalError::Unavailable)}
}

pub struct CoordinatorKnowledgeJournalLower{coordinator:Arc<Mutex<EstateCoordinator>>} impl CoordinatorKnowledgeJournalLower{pub fn new(coordinator:Arc<Mutex<EstateCoordinator>>)->Self{Self{coordinator}}}
impl CoordinatorKnowledgeJournalLower {
    fn visible_tunnels(&self,a:&V2KnowledgeJournalAdmission,tunnels:Vec<Tunnel>,limit:usize)->Result<Vec<V2KnowledgeTunnel>,()> { let c=self.coordinator.lock().map_err(|_|())?;let estate=c.estate_for(&a.estate_handle).map_err(|_|())?;let mut seen=BTreeSet::new();let mut rows=Vec::new();for t in tunnels {if !seen.insert(t.id.clone())||t.adjective_sensitivity().raw_value()>a.maximum_sensitivity.raw_value(){continue;} let endpoints=[t.source_drawer_id.as_deref(),t.target_drawer_id.as_deref()].into_iter().flatten().map(|id|estate.drawer_by_id(id).map_err(|_|())?.ok_or(())).collect::<Result<Vec<_>,()>>()?;if endpoints.iter().any(|drawer|drawer.adjective_sensitivity().raw_value()>a.maximum_sensitivity.raw_value()){continue;} let tid=Uuid::parse_str(&t.id).map_err(|_|())?;let from=t.source_drawer_id.as_deref().map(Uuid::parse_str).transpose().map_err(|_|())?;let to=t.target_drawer_id.as_deref().map(Uuid::parse_str).transpose().map_err(|_|())?;rows.push(V2KnowledgeTunnel{tunnel_id:tid,from_id:from,to_id:to,kind:tunnel_kind_wire(t.kind),lifecycle:format!("{:?}",t.lifecycle()).to_lowercase()});if rows.len()==limit{break;}}Ok(rows) }
    fn visible_fact(&self,a:&V2KnowledgeJournalAdmission,f:KGFact)->Result<Option<V2KnowledgeFact>,()> {if f.adjective_sensitivity().raw_value()>a.maximum_sensitivity.raw_value(){return Ok(None);}let source_memory_id=if f.source_drawer_id.is_empty(){None}else{let c=self.coordinator.lock().map_err(|_|())?;let estate=c.estate_for(&a.estate_handle).map_err(|_|())?;let d=estate.drawer_by_id(&f.source_drawer_id).map_err(|_|())?.ok_or(())?;if d.adjective_sensitivity().raw_value()>a.maximum_sensitivity.raw_value(){return Ok(None);}Some(Uuid::parse_str(&f.source_drawer_id).map_err(|_|())?)};let state=format!("{:?}",f.state());Ok(Some(V2KnowledgeFact{fact_id:Uuid::parse_str(&f.id).map_err(|_|())?,subject:f.subject,predicate:f.predicate,object:f.object,source_memory_id,event_time_millis:f.filed_at,state})) }
}
impl V2KnowledgeJournalLower for CoordinatorKnowledgeJournalLower {
    fn connection_search(&self,a:&V2KnowledgeJournalAdmission,r:&V2ConnectionSearchRequest)->Result<Vec<V2KnowledgeTunnel>,()>{let c=self.coordinator.lock().map_err(|_|())?;let all=c.all_tunnels(&a.estate_handle).map_err(|_|())?;drop(c);let id=r.memory_id.to_string();self.visible_tunnels(a,all.into_iter().filter(|t|t.lifecycle()==TunnelLifecycle::Active).filter(|t|(matches!(r.direction,V2ConnectionDirection::Outgoing|V2ConnectionDirection::Both)&&t.source_drawer_id.as_deref()==Some(id.as_str()))||(matches!(r.direction,V2ConnectionDirection::Incoming|V2ConnectionDirection::Both)&&t.target_drawer_id.as_deref()==Some(id.as_str()))).filter(|t|r.relationship.as_deref().map_or(true,|v|t.label==v)).collect(),r.limit)}
    fn connection_map(&self,a:&V2KnowledgeJournalAdmission,r:&V2ConnectionMapRequest)->Result<Vec<V2KnowledgeTunnel>,()>{let c=self.coordinator.lock().map_err(|_|())?;let all=c.all_tunnels(&a.estate_handle).map_err(|_|())?;drop(c);let mut frontier=HashSet::from([r.memory_id.to_string()]);let mut visited=frontier.clone();let mut collected=Vec::new();for _ in 0..r.depth{if frontier.is_empty(){break;}for t in &all{if t.lifecycle()!=TunnelLifecycle::Active{continue;}if t.source_drawer_id.as_ref().is_some_and(|x|frontier.contains(x))||t.target_drawer_id.as_ref().is_some_and(|x|frontier.contains(x)){collected.push(t.clone());}}let visible=self.visible_tunnels(a,collected.clone(),r.limit)?;frontier=visible.into_iter().flat_map(|t|[t.from_id,t.to_id]).flatten().map(|id|id.to_string()).filter(|id|visited.insert(id.clone())).collect();}self.visible_tunnels(a,collected,r.limit)}
    fn file_fact(&self,a:&V2KnowledgeJournalAdmission,r:&V2FileFactRequest)->Result<V2KnowledgeFact,()>{if let Some(source)=r.source_memory_id{let c=self.coordinator.lock().map_err(|_|())?;let e=c.estate_for(&a.estate_handle).map_err(|_|())?;let d=e.drawer_by_id(&source.to_string()).map_err(|_|())?.ok_or(())?;if d.adjective_sensitivity().raw_value()>a.maximum_sensitivity.raw_value(){return Err(());}}let c=self.coordinator.lock().map_err(|_|())?;let origin=KGFactOrigin{added_by:a.caller_binding.clone(),..KGFactOrigin::default()};let fact=c.add_kg_fact_with_origin(&a.estate_handle,&r.subject,&r.predicate,&r.object,&r.source_memory_id.map(|v|v.to_string()).unwrap_or_default(),&origin,r.event_time_millis.unwrap_or(a.now_millis)).map_err(|_|())?;drop(c);self.visible_fact(a,fact)?.ok_or(())}
    fn fact_search(&self,a:&V2KnowledgeJournalAdmission,r:&V2FactSearchRequest)->Result<Vec<V2KnowledgeFact>,()>{let c=self.coordinator.lock().map_err(|_|())?;let facts=c.recall_kg_facts(&a.estate_handle).map_err(|_|())?;drop(c);let mut out=Vec::new();for f in facts{let matches=r.subject.as_deref().map_or(true,|v|f.subject==v)&&r.predicate.as_deref().map_or(true,|v|f.predicate==v)&&r.object.as_deref().map_or(true,|v|f.object==v)&&r.query.as_deref().map_or(true,|v|{let q=v.to_lowercase();f.subject.to_lowercase().contains(&q)||f.predicate.to_lowercase().contains(&q)||f.object.to_lowercase().contains(&q)});if matches{if let Some(v)=self.visible_fact(a,f)?{out.push(v);if out.len()==r.limit{break;}}}}Ok(out)}
    fn retire_fact(&self,a:&V2KnowledgeJournalAdmission,r:&V2RetireFactRequest)->Result<(),()>{self.coordinator.lock().map_err(|_|())?.withdraw_kg_fact(&a.estate_handle,&r.fact_id.to_string(),a.now_millis).map_err(|_|())}
    fn fact_timeline(&self,a:&V2KnowledgeJournalAdmission,r:&V2FactTimelineRequest)->Result<Vec<V2KnowledgeFact>,()>{let c=self.coordinator.lock().map_err(|_|())?;let facts=c.recall_kg_fact_timeline(&a.estate_handle,Some(&r.subject)).map_err(|_|())?;drop(c);let mut out=Vec::new();for f in facts.into_iter().filter(|f|f.subject==r.subject&&r.predicate.as_deref().map_or(true,|p|f.predicate==p)){if let Some(v)=self.visible_fact(a,f)?{out.push(v);if out.len()==r.limit{break;}}}Ok(out)}
    fn write_journal(&self,a:&V2KnowledgeJournalAdmission,r:&V2WriteJournalRequest)->Result<V2JournalEntry,()>{let e=self.coordinator.lock().map_err(|_|())?.add_diary_entry(&a.estate_handle,"mcp-agent",&r.content,r.tags.as_deref().unwrap_or("mcp-session"),"default",r.entry_time_millis.unwrap_or(a.now_millis)).map_err(|_|())?;Ok(V2JournalEntry{agent_name:e.agent_name,entry:e.entry,written_at_millis:e.filed_at})}
    fn read_journal(&self,a:&V2KnowledgeJournalAdmission,r:&V2ReadJournalRequest)->Result<Vec<V2JournalEntry>,()>{let entries=self.coordinator.lock().map_err(|_|())?.diary_entries(&a.estate_handle,"mcp-agent",r.limit).map_err(|_|())?;Ok(entries.into_iter().filter(|e|r.before_millis.map_or(true,|v|e.filed_at<v)&&r.after_millis.map_or(true,|v|e.filed_at>v)).map(|e|V2JournalEntry{agent_name:e.agent_name,entry:e.entry,written_at_millis:e.filed_at}).collect())}
}
