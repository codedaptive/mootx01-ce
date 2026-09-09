//! Typed, snapshot-backed v2 memory enumeration.
//!
//! This is deliberately unregistered. Surface integration owns operation
//! advertisement and estate routing. Its provider boundary must capture a
//! complete immutable inventory; it must never adapt a paged query or legacy
//! runner result.

use std::{collections::HashMap, sync::Mutex};

use serde::Serialize;
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use uuid::Uuid;

pub const MEMORY_LIST_TOOL: &str = "moot_memory_list";
pub const MEMORY_LIST_DEFAULT_LIMIT: usize = 200;
pub const MEMORY_LIST_MAX_LIMIT: usize = 200;
pub const CURSOR_TTL_MILLIS: i64 = 10 * 60 * 1_000;
pub const CURSOR_MAX_PER_AUTHORIZATION: usize = 32;
pub const CURSOR_MAX_SERVER_WIDE: usize = 256;
pub const CURSOR_MAX_SERIALIZED_BYTES: usize = 16 * 1024 * 1024;
pub const SNAPSHOT_MAX_ROWS_PER_TABLE: usize = 250_000;
pub const SNAPSHOT_MAX_SERIALIZED_BYTES: usize = 128 * 1024 * 1024;
const REVISION_VERSION: &str = "moot_memory_list_revision_v1";
const UUID_BYTE_ORDER: &str = "uuid_bytes_ascending";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MemoryListRequest {
    pub estate_id: Option<Uuid>,
    pub wing: String,
    pub room: Option<String>,
    pub filter: Option<MemoryListFilter>,
    pub limit: usize,
    pub cursor: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MemoryListFilter {
    MissingSubject,
}

impl MemoryListFilter {
    fn as_str(self) -> &'static str {
        match self {
            Self::MissingSubject => "missing_subject",
        }
    }
}

impl MemoryListRequest {
    pub fn decode(value: &Value) -> Result<Self, MemoryListError> {
        let object = value
            .as_object()
            .ok_or_else(|| MemoryListError::invalid("$", "must be an object"))?;
        for key in object.keys() {
            if !matches!(
                key.as_str(),
                "estate_id" | "wing" | "room" | "filter" | "limit" | "cursor"
            ) {
                return Err(MemoryListError::invalid(
                    format!("$.{key}"),
                    "is not accepted by this operation",
                ));
            }
        }
        let wing = required_string(object, "wing")?;
        if wing.is_empty() {
            return Err(MemoryListError::invalid("$.wing", "must not be empty"));
        }
        let room = optional_string(object, "room")?.filter(|value| !value.is_empty());
        let filter = match optional_string(object, "filter")?.as_deref() {
            None => None,
            Some("missing_subject") => Some(MemoryListFilter::MissingSubject),
            Some(_) => {
                return Err(MemoryListError::invalid(
                    "$.filter",
                    "must be missing_subject when supplied",
                ))
            }
        };
        let limit = match object.get("limit") {
            None => MEMORY_LIST_DEFAULT_LIMIT,
            Some(Value::Number(number)) => number
                .as_u64()
                .filter(|value| (1..=MEMORY_LIST_MAX_LIMIT as u64).contains(value))
                .map(|value| value as usize)
                .ok_or_else(|| {
                    MemoryListError::invalid("$.limit", "must be an integer from 1 through 200")
                })?,
            Some(_) => {
                return Err(MemoryListError::invalid(
                    "$.limit",
                    "must be an integer from 1 through 200",
                ))
            }
        };
        let cursor = optional_string(object, "cursor")?;
        if matches!(cursor.as_deref(), Some("")) {
            return Err(MemoryListError::invalid("$.cursor", "must not be empty"));
        }
        Ok(Self {
            estate_id: optional_uuid(object, "estate_id")?,
            wing,
            room,
            filter,
            limit,
            cursor,
        })
    }

    fn scope(&self, estate_id: Uuid) -> MemoryListScope {
        MemoryListScope {
            estate_id,
            wing: self.wing.clone(),
            room: self.room.clone(),
            filter: self.filter,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct MemoryListScope {
    estate_id: Uuid,
    wing: String,
    room: Option<String>,
    filter: Option<MemoryListFilter>,
}

/// The caller and policy binding that a cursor may never cross.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MemoryListAuthorization {
    pub caller_binding: String,
    pub context_id: String,
    pub policy_version: String,
}

/// A strict interpretation of one immutable PersistenceKit snapshot. The
/// provider applies the requested scope while building this complete,
/// authorized inventory and fails rather than omitting corrupt relevant data.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MemoryListSnapshot {
    pub estate_id: Uuid,
    pub authorization_generation: String,
    pub drawer_rows: usize,
    pub node_rows: usize,
    pub serialized_row_bytes: usize,
    pub rows: Vec<MemoryListSnapshotRow>,
}

pub type MemoryListProjection = Map<String, Value>;

/// A public row materialized from a complete authorized snapshot. Projection
/// values intentionally retain JSON nulls: a missing key and a null key have
/// different transcript-list semantics and revision identities.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MemoryListSnapshotRow {
    pub memory_id: Uuid,
    pub ancestry_ids: Vec<Uuid>,
    pub ancestry_names: Vec<String>,
    pub eligibility_state: String,
    pub visibility_state: String,
    pub projection: MemoryListProjection,
}

/// The only lower-kit seam. Production implementations authorize, capture the
/// two PersistenceKit tables atomically, strictly decode/validate their
/// ancestry, apply scope, and return the complete authorized state.
pub trait MemoryListSnapshotProvider: Send + Sync {
    fn authorize(
        &self,
        requested_estate_id: Option<Uuid>,
    ) -> Result<MemoryListAuthorization, MemoryListError>;

    fn capture_authorized_inventory(
        &self,
        authorization: &MemoryListAuthorization,
        wing: &str,
        room: Option<&str>,
        filter: Option<MemoryListFilter>,
    ) -> Result<MemoryListSnapshot, MemoryListError>;

    fn revalidate(&self, authorization: &MemoryListAuthorization) -> Result<(), MemoryListError>;
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct MemoryListPage {
    pub memories: Vec<MemoryListProjection>,
    pub has_more: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub next_cursor: Option<String>,
    pub revision: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MemoryListError {
    pub code: &'static str,
    pub path: Option<String>,
    pub message: String,
    pub retryable: bool,
}

impl MemoryListError {
    pub fn invalid(path: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: "invalid_argument",
            path: Some(path.into()),
            message: message.into(),
            retryable: false,
        }
    }

    pub fn inventory_too_large(message: impl Into<String>) -> Self {
        Self {
            code: "inventory_too_large",
            path: None,
            message: message.into(),
            retryable: true,
        }
    }

    pub fn operational(code: &'static str, message: impl Into<String>, retryable: bool) -> Self {
        Self {
            code,
            path: None,
            message: message.into(),
            retryable,
        }
    }
}

pub struct MemoryListService<P> {
    provider: P,
    cursors: std::sync::Arc<MemoryListCursorStore>,
    default_estate_id: Uuid,
}

impl<P: MemoryListSnapshotProvider> MemoryListService<P> {
    pub fn new(provider: P, default_estate_id: Uuid) -> Self {
        Self::new_with_cursor_store(
            provider,
            default_estate_id,
            std::sync::Arc::new(MemoryListCursorStore::new()),
        )
    }

    /// Build a request service over a selected-surface-owned cursor store.
    /// The store contains opaque continuation state only, so sharing it does
    /// not retain a snapshot or cross an authorization binding.
    pub(crate) fn new_with_cursor_store(
        provider: P,
        default_estate_id: Uuid,
        cursors: std::sync::Arc<MemoryListCursorStore>,
    ) -> Self {
        Self {
            provider,
            cursors,
            default_estate_id,
        }
    }

    pub fn list(
        &self,
        request: MemoryListRequest,
        now_millis: i64,
    ) -> Result<MemoryListPage, MemoryListError> {
        let estate_id = request.estate_id.unwrap_or(self.default_estate_id);
        let authorization = self.provider.authorize(request.estate_id)?;
        self.provider.revalidate(&authorization)?;
        let snapshot = self.provider.capture_authorized_inventory(
            &authorization,
            &request.wing,
            request.room.as_deref(),
            request.filter,
        )?;
        validate_snapshot(&snapshot)?;
        self.provider.revalidate(&authorization)?;
        if snapshot.estate_id != estate_id {
            return Err(MemoryListError::operational(
                "inventory_unavailable",
                "The complete authorized memory inventory is unavailable.",
                true,
            ));
        }

        let scope = request.scope(estate_id);
        let rows = ordered_rows(snapshot.rows)?;
        let revision = revision(
            &authorization,
            &snapshot.authorization_generation,
            &scope,
            &rows,
        );
        let continuation = match request.cursor.as_deref() {
            None => None,
            Some(cursor) => {
                Some(
                    self.cursors
                        .lookup(cursor, &authorization, &scope, now_millis)?,
                )
            }
        };
        if let Some(cursor) = continuation.as_ref() {
            if cursor.revision != revision {
                return Err(MemoryListError::operational(
                    "cursor_stale",
                    "The inventory changed; restart moot_memory_list without the cursor.",
                    true,
                ));
            }
        }
        let start = continuation
            .as_ref()
            .map(|cursor| {
                rows.partition_point(|row| {
                    row.memory_id.as_bytes() <= cursor.last_memory_id.as_bytes()
                })
            })
            .unwrap_or(0);
        let end = start.saturating_add(request.limit).min(rows.len());
        let memories = rows[start..end].iter().map(project).collect::<Vec<_>>();
        let has_more = end < rows.len();
        let next_cursor = if has_more {
            let last_memory_id = rows[end - 1].memory_id;
            Some(self.cursors.insert(CursorSession::new(
                authorization,
                scope,
                revision.clone(),
                last_memory_id,
                now_millis,
            ))?)
        } else {
            None
        };
        Ok(MemoryListPage {
            memories,
            has_more,
            next_cursor,
            revision,
        })
    }
}

fn validate_snapshot(snapshot: &MemoryListSnapshot) -> Result<(), MemoryListError> {
    if snapshot.drawer_rows > SNAPSHOT_MAX_ROWS_PER_TABLE
        || snapshot.node_rows > SNAPSHOT_MAX_ROWS_PER_TABLE
    {
        return Err(MemoryListError::inventory_too_large(
            "The inventory snapshot exceeds the 250000-row table limit.",
        ));
    }
    if snapshot.serialized_row_bytes > SNAPSHOT_MAX_SERIALIZED_BYTES {
        return Err(MemoryListError::inventory_too_large(
            "The inventory snapshot exceeds the 128 MiB storage-row limit.",
        ));
    }
    Ok(())
}

fn ordered_rows(
    mut rows: Vec<MemoryListSnapshotRow>,
) -> Result<Vec<MemoryListSnapshotRow>, MemoryListError> {
    rows.sort_by(|left, right| left.memory_id.as_bytes().cmp(right.memory_id.as_bytes()));
    if rows
        .windows(2)
        .any(|pair| pair[0].memory_id == pair[1].memory_id)
    {
        return Err(MemoryListError::operational(
            "inventory_unavailable",
            "The complete authorized memory inventory is unavailable.",
            true,
        ));
    }
    Ok(rows)
}

fn project(row: &MemoryListSnapshotRow) -> MemoryListProjection {
    let mut value = row.projection.clone();
    value.insert(
        "memory_id".to_owned(),
        Value::String(row.memory_id.hyphenated().to_string()),
    );
    value
}

fn revision(
    authorization: &MemoryListAuthorization,
    authorization_generation: &str,
    scope: &MemoryListScope,
    rows: &[MemoryListSnapshotRow],
) -> String {
    let material = Value::Object(Map::from_iter([
        (
            "authorization".to_owned(),
            Value::Object(Map::from_iter([
                (
                    "authorization_generation".to_owned(),
                    Value::String(authorization_generation.to_owned()),
                ),
                (
                    "caller_binding".to_owned(),
                    Value::String(authorization.caller_binding.clone()),
                ),
                (
                    "context_id".to_owned(),
                    Value::String(authorization.context_id.clone()),
                ),
                (
                    "policy_version".to_owned(),
                    Value::String(authorization.policy_version.clone()),
                ),
            ])),
        ),
        (
            "estate_id".to_owned(),
            Value::String(scope.estate_id.hyphenated().to_string()),
        ),
        (
            "revision_version".to_owned(),
            Value::String(REVISION_VERSION.to_owned()),
        ),
        (
            "rows".to_owned(),
            Value::Array(rows.iter().map(revision_row).collect()),
        ),
        (
            "scope".to_owned(),
            Value::Object(Map::from_iter([
                (
                    "filter".to_owned(),
                    scope.filter.map_or(Value::Null, |filter| {
                        Value::String(filter.as_str().to_owned())
                    }),
                ),
                (
                    "order".to_owned(),
                    Value::String(UUID_BYTE_ORDER.to_owned()),
                ),
                (
                    "room".to_owned(),
                    scope.room.clone().map_or(Value::Null, Value::String),
                ),
                ("wing".to_owned(), Value::String(scope.wing.clone())),
            ])),
        ),
        (
            "total".to_owned(),
            Value::Number((rows.len() as u64).into()),
        ),
    ]));
    let canonical = canonical_json(&material);
    format!("{:x}", Sha256::digest(canonical.as_bytes()))
}

fn revision_row(row: &MemoryListSnapshotRow) -> Value {
    Value::Object(Map::from_iter([
        (
            "ancestry_ids".to_owned(),
            Value::Array(
                row.ancestry_ids
                    .iter()
                    .map(|id| Value::String(id.hyphenated().to_string()))
                    .collect(),
            ),
        ),
        (
            "ancestry_names".to_owned(),
            Value::Array(
                row.ancestry_names
                    .iter()
                    .map(|name| Value::String(name.clone()))
                    .collect(),
            ),
        ),
        (
            "eligibility".to_owned(),
            Value::String(row.eligibility_state.clone()),
        ),
        (
            "memory_id".to_owned(),
            Value::String(row.memory_id.hyphenated().to_string()),
        ),
        (
            "projection".to_owned(),
            Value::Object(row.projection.clone()),
        ),
        (
            "visibility".to_owned(),
            Value::String(row.visibility_state.clone()),
        ),
    ]))
}

fn canonical_json(value: &Value) -> String {
    match value {
        Value::Null => "null".to_owned(),
        Value::Bool(value) => value.to_string(),
        Value::Number(value) => value.to_string(),
        Value::String(value) => {
            serde_json::to_string(value).expect("JSON string serialization is infallible")
        }
        Value::Array(values) => format!(
            "[{}]",
            values
                .iter()
                .map(canonical_json)
                .collect::<Vec<_>>()
                .join(",")
        ),
        Value::Object(values) => {
            let mut keys = values.keys().collect::<Vec<_>>();
            keys.sort_unstable_by(|left, right| left.as_bytes().cmp(right.as_bytes()));
            format!(
                "{{{}}}",
                keys.into_iter()
                    .map(|key| {
                        format!(
                            "{}:{}",
                            canonical_json(&Value::String(key.clone())),
                            canonical_json(&values[key])
                        )
                    })
                    .collect::<Vec<_>>()
                    .join(",")
            )
        }
    }
}

#[derive(Debug, Clone)]
struct CursorSession {
    authorization: MemoryListAuthorization,
    scope: MemoryListScope,
    revision: String,
    last_memory_id: Uuid,
    created_at: i64,
    last_used_at: i64,
}

impl CursorSession {
    fn new(
        authorization: MemoryListAuthorization,
        scope: MemoryListScope,
        revision: String,
        last_memory_id: Uuid,
        now_millis: i64,
    ) -> Self {
        Self {
            authorization,
            scope,
            revision,
            last_memory_id,
            created_at: now_millis,
            last_used_at: now_millis,
        }
    }

    fn expires_at(&self) -> i64 {
        self.created_at.saturating_add(CURSOR_TTL_MILLIS)
    }

    fn serialized_bytes(&self) -> usize {
        40 + self.authorization.caller_binding.len()
            + self.authorization.context_id.len()
            + self.authorization.policy_version.len()
            + self.scope.wing.len()
            + self.scope.room.as_ref().map_or(0, String::len)
            + self.revision.len()
    }
}

pub(crate) struct MemoryListCursorStore {
    state: Mutex<CursorState>,
}

struct CursorState {
    sessions: HashMap<String, CursorSession>,
    serialized_bytes: usize,
}

impl MemoryListCursorStore {
    pub(crate) fn new() -> Self {
        Self {
            state: Mutex::new(CursorState {
                sessions: HashMap::new(),
                serialized_bytes: 0,
            }),
        }
    }

    fn lookup(
        &self,
        token: &str,
        authorization: &MemoryListAuthorization,
        scope: &MemoryListScope,
        now_millis: i64,
    ) -> Result<CursorSession, MemoryListError> {
        let mut state = self.state.lock().map_err(|_| {
            MemoryListError::operational(
                "cursor_unavailable",
                "Cursor storage is unavailable.",
                true,
            )
        })?;
        evict_expired(&mut state, now_millis);
        let session = state.sessions.get_mut(token).ok_or_else(|| {
            MemoryListError::operational(
                "cursor_expired",
                "The cursor expired or was evicted; restart moot_memory_list.",
                true,
            )
        })?;
        if session.authorization != *authorization || session.scope != *scope {
            return Err(MemoryListError::operational(
                "cursor_mismatch",
                "The cursor does not match this caller or list scope; restart moot_memory_list.",
                false,
            ));
        }
        session.last_used_at = now_millis;
        Ok(session.clone())
    }

    fn insert(&self, session: CursorSession) -> Result<String, MemoryListError> {
        let mut state = self.state.lock().map_err(|_| {
            MemoryListError::operational(
                "cursor_unavailable",
                "Cursor storage is unavailable.",
                true,
            )
        })?;
        evict_expired(&mut state, session.created_at);
        while state
            .sessions
            .values()
            .filter(|existing| existing.authorization == session.authorization)
            .count()
            >= CURSOR_MAX_PER_AUTHORIZATION
        {
            evict_lru(&mut state, |existing| {
                existing.authorization == session.authorization
            });
        }
        while state.sessions.len() >= CURSOR_MAX_SERVER_WIDE
            || state
                .serialized_bytes
                .saturating_add(session.serialized_bytes())
                > CURSOR_MAX_SERIALIZED_BYTES
        {
            if state.sessions.is_empty() {
                return Err(MemoryListError::operational(
                    "cursor_limit",
                    "The cursor state exceeds the server limit; restart later.",
                    true,
                ));
            }
            evict_lru(&mut state, |_| true);
        }
        let token = Uuid::new_v4().hyphenated().to_string();
        state.serialized_bytes = state
            .serialized_bytes
            .saturating_add(session.serialized_bytes());
        state.sessions.insert(token.clone(), session);
        Ok(token)
    }
}

fn evict_expired(state: &mut CursorState, now_millis: i64) {
    let expired = state
        .sessions
        .iter()
        .filter_map(|(token, session)| (session.expires_at() <= now_millis).then(|| token.clone()))
        .collect::<Vec<_>>();
    for token in expired {
        if let Some(session) = state.sessions.remove(&token) {
            state.serialized_bytes = state
                .serialized_bytes
                .saturating_sub(session.serialized_bytes());
        }
    }
}

fn evict_lru(state: &mut CursorState, predicate: impl Fn(&CursorSession) -> bool) {
    let victim = state
        .sessions
        .iter()
        .filter(|(_, session)| predicate(session))
        .min_by_key(|(_, session)| session.last_used_at)
        .map(|(token, _)| token.clone());
    if let Some(token) = victim {
        if let Some(session) = state.sessions.remove(&token) {
            state.serialized_bytes = state
                .serialized_bytes
                .saturating_sub(session.serialized_bytes());
        }
    }
}

fn required_string(object: &Map<String, Value>, key: &str) -> Result<String, MemoryListError> {
    optional_string(object, key)?
        .ok_or_else(|| MemoryListError::invalid(format!("$.{key}"), "is required"))
}

fn optional_string(
    object: &Map<String, Value>,
    key: &str,
) -> Result<Option<String>, MemoryListError> {
    match object.get(key) {
        None => Ok(None),
        Some(Value::String(value)) => Ok(Some(value.clone())),
        Some(_) => Err(MemoryListError::invalid(
            format!("$.{key}"),
            "must be a string",
        )),
    }
}

fn optional_uuid(object: &Map<String, Value>, key: &str) -> Result<Option<Uuid>, MemoryListError> {
    optional_string(object, key)?
        .map(|value| {
            let groups = value.split('-').collect::<Vec<_>>();
            let hyphenated = matches!(groups.as_slice(), [a, b, c, d, e]
            if a.len() == 8 && b.len() == 4 && c.len() == 4 && d.len() == 4 && e.len() == 12)
                && value
                    .bytes()
                    .all(|byte| byte == b'-' || byte.is_ascii_hexdigit());
            if !hyphenated {
                return Err(MemoryListError::invalid(
                    format!("$.{key}"),
                    "must be a hyphenated UUID",
                ));
            }
            Uuid::parse_str(&value)
                .map_err(|_| MemoryListError::invalid(format!("$.{key}"), "must be a valid UUID"))
        })
        .transpose()
}
