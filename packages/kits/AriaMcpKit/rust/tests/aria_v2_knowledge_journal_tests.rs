#![cfg(feature = "aria-v2")]

#[path = "../src/jsonrpc.rs"] mod jsonrpc;
#[path = "../src/v2/codec.rs"] mod codec;
#[path = "../src/v2/knowledge_journal.rs"] mod knowledge_journal;

use std::{collections::BTreeMap, sync::Mutex};
use genius_locus_kit::EstateHandle;
use jsonrpc::JsonValue;
use knowledge_journal::*;
use locus_kit::adjectives::AdjectiveSensitivity;
use uuid::Uuid;

fn uuid(s:&str)->Uuid{Uuid::parse_str(s).unwrap()}
fn args(items:impl IntoIterator<Item=(&'static str,JsonValue)>)->JsonValue{JsonValue::Object(items.into_iter().map(|(k,v)|(k.to_owned(),v)).collect::<BTreeMap<_,_>>())}
const ESTATE:&str="11111111-1111-4111-8111-111111111111"; const FACT:&str="22222222-2222-4222-8222-222222222222";
#[derive(Default)] struct Authority{calls:Mutex<Vec<V2KnowledgeJournalOperation>>}
impl V2KnowledgeJournalAuthority for Authority{fn admit(&self,op:V2KnowledgeJournalOperation,estate:Option<Uuid>)->Result<V2KnowledgeJournalAdmission,()>{assert!(estate.is_none()||estate==Some(uuid(ESTATE)));self.calls.lock().unwrap().push(op);Ok(V2KnowledgeJournalAdmission{estate_id:uuid(ESTATE),estate_handle:EstateHandle::new([1;16],0,0).unwrap(),caller_binding:"test".to_owned(),maximum_sensitivity:AdjectiveSensitivity::Elevated,now_millis:10})}}
struct Lower; impl V2KnowledgeJournalLower for Lower{fn connection_search(&self,_:&V2KnowledgeJournalAdmission,_:&V2ConnectionSearchRequest)->Result<Vec<V2KnowledgeTunnel>,()>{Ok(vec![])}fn connection_map(&self,_:&V2KnowledgeJournalAdmission,_:&V2ConnectionMapRequest)->Result<Vec<V2KnowledgeTunnel>,()>{Ok(vec![])}fn file_fact(&self,_:&V2KnowledgeJournalAdmission,_:&V2FileFactRequest)->Result<V2KnowledgeFact,()>{Ok(fact())}fn fact_search(&self,_:&V2KnowledgeJournalAdmission,_:&V2FactSearchRequest)->Result<Vec<V2KnowledgeFact>,()>{Ok(vec![fact()])}fn retire_fact(&self,_:&V2KnowledgeJournalAdmission,_:&V2RetireFactRequest)->Result<(),()>{Ok(())}fn fact_timeline(&self,_:&V2KnowledgeJournalAdmission,_:&V2FactTimelineRequest)->Result<Vec<V2KnowledgeFact>,()>{Ok(vec![fact()])}fn write_journal(&self,_:&V2KnowledgeJournalAdmission,_:&V2WriteJournalRequest)->Result<V2JournalEntry,()>{Ok(V2JournalEntry{agent_name:"mcp-agent".to_owned(),entry:"entry".to_owned(),written_at_millis:10})}fn read_journal(&self,_:&V2KnowledgeJournalAdmission,_:&V2ReadJournalRequest)->Result<Vec<V2JournalEntry>,()>{Ok(vec![])}}
fn fact()->V2KnowledgeFact{V2KnowledgeFact{fact_id:uuid(FACT),subject:"s".to_owned(),predicate:"p".to_owned(),object:"o".to_owned(),source_memory_id:None,event_time_millis:10,state:"Active".to_owned()}}
#[test] fn frozen_keys_and_dates_decode_strictly(){let r=V2FileFactRequest::decode(&args([("subject",JsonValue::String("s".to_owned())),("predicate",JsonValue::String("p".to_owned())),("object",JsonValue::String("o".to_owned())),("event_time",JsonValue::String("2026-09-08T12:30:45.123Z".to_owned()))])).unwrap();assert_eq!(r.event_time_millis,Some(1_788_870_645_123));let bad=V2ConnectionSearchRequest::decode(&args([("memory_id",JsonValue::String(FACT.to_owned())),("legacy",JsonValue::Bool(true))])).unwrap_err();assert_eq!(bad.path,"$.legacy");}
#[test] fn source_less_fact_is_structured_none_not_a_sentinel_uuid(){let a=Authority::default();let service=V2KnowledgeJournalService::new(a,Lower);let result=service.file_fact(V2FileFactRequest{subject:"s".to_owned(),predicate:"p".to_owned(),object:"o".to_owned(),source_memory_id:None,event_time_millis:None,estate_id:None}).unwrap();let V2KnowledgeJournalResult::Fact(filed)=&result else { panic!("expected fact result") };assert_eq!(filed.source_memory_id,None);assert_eq!(result,V2KnowledgeJournalResult::Fact(fact()));}
#[test] fn stable_operation_identities_reach_the_direct_service(){let a=Authority::default();let service=V2KnowledgeJournalService::new(a,Lower);let result=service.retire_fact(V2RetireFactRequest{fact_id:uuid(FACT),reason:None,estate_id:None}).unwrap();assert_eq!(result,V2KnowledgeJournalResult::Retired{fact_id:uuid(FACT)});assert_eq!(V2KnowledgeJournalOperation::RetireFact.tool_name(),RETIRE_FACT_TOOL);}
