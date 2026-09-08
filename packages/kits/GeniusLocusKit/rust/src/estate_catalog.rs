// estate_catalog.rs — the registry of estates: which estates exist, what they
// are called, and where each one lives. Storage and retrieval of records,
// nothing else. The catalog never creates, opens, moves or deletes an
// estate's files; it only remembers where they are.
//
// Twin of `Sources/GeniusLocusKit/EstateCatalog.swift`. Both ports read and
// write the same `estatecatalog.json` and `estate.json` and must produce the
// same records for the same file. The Swift file's header carries the full
// account of the two directories and the two files; the short form:
//
// - The configuration directory is computed from the platform and the
//   product identity (`moot_product_identity::storage::configuration_directory`),
//   never passed in, stored or moved. It holds `estatecatalog.json`.
// - The default database location is recorded inside the catalog file as an
//   absolute path, `<configuration>/databases` on first run. Bare estate
//   names resolve under it. `move_default` refuses in this version.
// - `estate.json` inside every estate directory is the estate's own manifest.
// - Registered records live in the file; transient records come from
//   `--db <path>/<name>` for one invocation and are never written.
// - A record names its backend: SQLite (the default) keeps the database in
//   the directory; PostgreSQL keeps it at a connection string on the record.
// - `--db <value>` and `register <value>` share `EstateSelector`: the value
//   splits into a path and a name (the last component). A registered name
//   selects its record; an unregistered name with a path attaches a
//   transient record at `path/name/`; an unregistered bare name is refused.
//
// Paths are `std::path::PathBuf`s. The Swift port standardises URLs
// lexically (`standardizedFileURL`); `normalize` here does the same so the
// two ports record the same string for the same input.

use std::collections::BTreeMap;
use std::fmt;
use std::fs;
use std::io;
use std::path::{Component, Path, PathBuf};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use crate::estate_format::EstateFormatVersion;
use moot_product_identity::storage as identity;

// MARK: - Names

/// Every name the catalog and the estate layout use, in one place. Twin of
/// Swift `EstateCatalogNames`; change a name here and there together.
pub struct EstateCatalogNames;

impl EstateCatalogNames {
    /// The catalog file inside the configuration directory.
    pub const CATALOG_FILE: &'static str = identity::CATALOG_FILE;
    /// The folder under the configuration directory that is the default
    /// database location on first run.
    pub const DATABASES_FOLDER: &'static str = identity::DATABASES_FOLDER;
    /// The primary estate's name.
    pub const DEFAULT_ESTATE: &'static str = identity::DEFAULT_ESTATE_NAME;

    /// The files one estate owns, inside its directory.
    pub const MANIFEST: &'static str = "estate.json";
    pub const PID: &'static str = "estate.pid";
    pub const DATABASE: &'static str = identity::ESTATE_DATABASE_FILE;
    pub const DATABASE_WAL: &'static str = "estate.sqlite-wal";
    pub const DATABASE_SHM: &'static str = "estate.sqlite-shm";
    pub const QUEUE: &'static str = "estate.queue.sqlite";
    pub const QUEUE_WAL: &'static str = "estate.queue.sqlite-wal";
    pub const QUEUE_SHM: &'static str = "estate.queue.sqlite-shm";
    pub const VECTORS: &'static str = "estate.vectors.vec";
    pub const DRAIN_LEASE: &'static str = "encode.drain.lease";
    /// The pre-manifest plaintext marker. Not an owned file: `mootx01 upgrade`
    /// folds it into the manifest's `encryption` and deletes it.
    pub const LEGACY_ENCRYPTION_OPT_OUT: &'static str = "no-encrypt";
}

// MARK: - EstateRecord

/// Whether a record is stored in `estatecatalog.json` or exists for one invocation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum EstateRecordKind {
    Registered,
    Transient,
}

/// Which persistence backend holds the estate's database.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EstateBackend {
    /// `estate.sqlite` and its sidecars inside the record's directory. The
    /// default; a catalog entry without a `backend` field means this.
    Sqlite,
    /// A PostgreSQL database reached through the connection string. The
    /// record's directory holds the manifest and the process marker; the
    /// database files derived from the directory never exist for this backend.
    Postgresql { connection_string: String },
}

impl EstateBackend {
    /// The word `estatecatalog.json` records for each case.
    pub fn kind_name(&self) -> &'static str {
        match self {
            EstateBackend::Sqlite => "sqlite",
            EstateBackend::Postgresql { .. } => "postgresql",
        }
    }
}

/// The on-file shape of a backend: `{"kind": "sqlite"}` or
/// `{"kind": "postgresql", "connectionString": "..."}`. Spelled out rather
/// than derived on the enum so both ports read the same object.
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct BackendFile {
    kind: String,
    #[serde(rename = "connectionString", skip_serializing_if = "Option::is_none")]
    connection_string: Option<String>,
}

impl Serialize for EstateBackend {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let file = BackendFile {
            kind: self.kind_name().to_string(),
            connection_string: match self {
                EstateBackend::Sqlite => None,
                EstateBackend::Postgresql { connection_string } => Some(connection_string.clone()),
            },
        };
        file.serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for EstateBackend {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        use serde::de::Error;
        let file = BackendFile::deserialize(deserializer)?;
        match (file.kind.as_str(), file.connection_string) {
            ("sqlite", None) => Ok(EstateBackend::Sqlite),
            ("postgresql", Some(s)) if !s.is_empty() => Ok(EstateBackend::Postgresql { connection_string: s }),
            ("sqlite", Some(_)) => Err(D::Error::custom("a sqlite backend carries no connectionString")),
            ("postgresql", _) => Err(D::Error::custom("a postgresql backend needs a non-empty connectionString")),
            (other, _) => Err(D::Error::custom(format!("unknown backend kind '{other}'"))),
        }
    }
}

/// One estate: its name and the directory that holds it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EstateRecord {
    /// The name, one path component.
    pub name: String,
    /// The directory holding every file of the estate. Normalised.
    pub directory: PathBuf,
    /// Registered (in the file) or transient (this invocation only).
    pub kind: EstateRecordKind,
    /// Where the database lives. Transient records are always SQLite: `--db`
    /// names a directory and nothing else.
    pub backend: EstateBackend,
}

impl EstateRecord {
    /// A registered SQLite record. Twin of the Swift initialiser's defaults.
    pub fn new(name: impl Into<String>, directory: impl AsRef<Path>) -> Self {
        Self::with(name, directory, EstateRecordKind::Registered, EstateBackend::Sqlite)
    }

    /// A record of the given kind and backend.
    pub fn with(
        name: impl Into<String>,
        directory: impl AsRef<Path>,
        kind: EstateRecordKind,
        backend: EstateBackend,
    ) -> Self {
        EstateRecord { name: name.into(), directory: normalize(directory.as_ref()), kind, backend }
    }

    /// The estate's own manifest, `estate.json` (`EstateManifest`).
    pub fn manifest_path(&self) -> PathBuf { self.directory.join(EstateCatalogNames::MANIFEST) }
    /// The process marker written by whichever process is serving the estate.
    pub fn pid_path(&self) -> PathBuf { self.directory.join(EstateCatalogNames::PID) }
    /// The estate database.
    pub fn database_path(&self) -> PathBuf { self.directory.join(EstateCatalogNames::DATABASE) }
    /// SQLite write-ahead log and shared-memory sidecars of the database.
    pub fn database_wal_path(&self) -> PathBuf { self.directory.join(EstateCatalogNames::DATABASE_WAL) }
    pub fn database_shm_path(&self) -> PathBuf { self.directory.join(EstateCatalogNames::DATABASE_SHM) }
    /// The dreaming and encode queue database and its SQLite sidecars.
    pub fn queue_path(&self) -> PathBuf { self.directory.join(EstateCatalogNames::QUEUE) }
    pub fn queue_wal_path(&self) -> PathBuf { self.directory.join(EstateCatalogNames::QUEUE_WAL) }
    pub fn queue_shm_path(&self) -> PathBuf { self.directory.join(EstateCatalogNames::QUEUE_SHM) }
    /// The resident vector arrays (binary fingerprints and float vectors).
    pub fn vectors_path(&self) -> PathBuf { self.directory.join(EstateCatalogNames::VECTORS) }
    /// The encode-drain lease that serialises drainers on this estate.
    pub fn drain_lease_path(&self) -> PathBuf { self.directory.join(EstateCatalogNames::DRAIN_LEASE) }
    /// The pre-manifest plaintext marker, if an older estate still carries it.
    /// Read only by `mootx01 upgrade`, which folds it into the manifest.
    pub fn legacy_encryption_opt_out_path(&self) -> PathBuf {
        self.directory.join(EstateCatalogNames::LEGACY_ENCRYPTION_OPT_OUT)
    }

    /// The `--db <value>` that selects this estate again in another process:
    /// the name for a registered estate, the directory path for a transient
    /// one. Detached children (drain, dream) are launched with this.
    pub fn selector_argument(&self) -> String {
        match self.kind {
            EstateRecordKind::Registered => self.name.clone(),
            EstateRecordKind::Transient => self.directory.to_string_lossy().into_owned(),
        }
    }

    /// Every file the estate owns, in a fixed order. Deletion, copy and
    /// inventory walk this list and nothing else. For a PostgreSQL record
    /// only the manifest and the process marker can exist; the rest are
    /// derived names that no process creates, and walkers skip absent files.
    pub fn owned_file_paths(&self) -> Vec<PathBuf> {
        vec![
            self.manifest_path(), self.pid_path(),
            self.database_path(), self.database_wal_path(), self.database_shm_path(),
            self.queue_path(), self.queue_wal_path(), self.queue_shm_path(),
            self.vectors_path(), self.drain_lease_path(),
        ]
    }
}

// MARK: - EstateManifest

/// At-rest encryption posture recorded in the manifest.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum EstateManifestEncryption {
    Encrypted,
    Plaintext,
}

/// The estate's own manifest, stored as `estate.json` in its directory.
/// Written when the estate is created and whenever a recorded fact changes;
/// read by anything that needs to know about the estate without opening it.
///
/// Field order is alphabetical because the Swift port writes sorted keys and
/// serde writes fields in declaration order; the two files then match.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EstateManifest {
    /// ISO8601, UTC. Passed in; the catalog never reads the clock.
    pub created: String,
    pub encryption: EstateManifestEncryption,
    /// The `estate.json` file format version.
    #[serde(rename = "fileVersion")]
    pub file_version: u32,
    /// The estate format the estate was last written at.
    #[serde(rename = "formatVersion")]
    pub format_version: EstateFormatVersion,
    /// The estate's name; the same word as its directory.
    pub name: String,
    /// The composite schema version the estate was last written at.
    #[serde(rename = "schemaVersion")]
    pub schema_version: u32,
}

impl EstateManifest {
    /// The `estate.json` file format version this code writes and accepts.
    pub const CURRENT_FILE_VERSION: u32 = 1;

    /// The only keys `estate.json` may carry. A manifest with any other key
    /// is refused: a path, a redirect or any field this version does not know
    /// could hide a rogue database under a manifest that looks right.
    pub const ALLOWED_KEYS: [&'static str; 6] =
        ["fileVersion", "name", "schemaVersion", "formatVersion", "encryption", "created"];

    pub fn new(
        name: impl Into<String>,
        schema_version: u32,
        format_version: EstateFormatVersion,
        encryption: EstateManifestEncryption,
        created: impl Into<String>,
    ) -> Self {
        EstateManifest {
            created: created.into(),
            encryption,
            file_version: Self::CURRENT_FILE_VERSION,
            format_version,
            name: name.into(),
            schema_version,
        }
    }
}

// MARK: - EstateCatalogError

/// Failures of the catalog. Every case names the file or estate involved.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EstateCatalogError {
    /// `estatecatalog.json` could not be read or was not valid JSON of the expected shape.
    UnreadableCatalog { path: PathBuf, detail: String },
    /// `estatecatalog.json` could not be written.
    UnwritableCatalog { path: PathBuf, detail: String },
    /// The catalog lists no estates.
    EmptyCatalog { path: PathBuf },
    /// A name that is not a valid estate name (empty, `.`, `..`, or containing a path separator).
    InvalidName(String),
    /// A record with this name is already registered.
    DuplicateName(String),
    /// No record with this name is registered.
    UnknownName(String),
    /// The active estate (index zero) cannot be removed; make another active first.
    CannotRemoveActive(String),
    /// `--db <value>` named an estate that is not registered and gave no path.
    UnregisteredWithoutPath(String),
    /// The operation exists in the interface but does nothing in this version.
    NotAvailableInThisVersion { operation: String },
    /// `estate.json` is missing, unreadable, or names a different estate.
    UnreadableEstateManifest { path: PathBuf, detail: String },
}

impl fmt::Display for EstateCatalogError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        use EstateCatalogError::*;
        match self {
            UnreadableCatalog { path, detail } =>
                write!(f, "estate catalog at {} is unreadable: {detail}", path.display()),
            UnwritableCatalog { path, detail } =>
                write!(f, "estate catalog at {} could not be written: {detail}", path.display()),
            EmptyCatalog { path } => write!(f, "estate catalog at {} lists no estates", path.display()),
            InvalidName(name) => write!(f, "'{name}' is not a valid estate name"),
            DuplicateName(name) => write!(f, "an estate named '{name}' is already registered"),
            UnknownName(name) => write!(f, "no estate named '{name}' is registered"),
            CannotRemoveActive(name) =>
                write!(f, "'{name}' is the active estate and cannot be removed; activate another estate first"),
            UnregisteredWithoutPath(value) =>
                write!(f, "'{value}' is not a registered estate; an unregistered estate needs a path (<dir>/{value})"),
            NotAvailableInThisVersion { operation } => write!(f, "{operation} is not available in this version"),
            UnreadableEstateManifest { path, detail } =>
                write!(f, "estate manifest at {} is unreadable: {detail}", path.display()),
        }
    }
}

impl std::error::Error for EstateCatalogError {}

// MARK: - EstateSelector

/// The split of a `--db <value>` or `register <value>` argument into the
/// path before the last component and the name that is the last component.
/// `~` expands; a relative pathname is relative to the working directory.
/// A value with no separator has no path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EstateSelector {
    pub name: String,
    pub path: Option<PathBuf>,
}

impl EstateSelector {
    pub fn parse(value: &str) -> Result<Self, EstateCatalogError> {
        let invalid = || EstateCatalogError::InvalidName(value.to_string());
        let expanded = expand_tilde(value);
        let trimmed = if expanded.len() > 1 && expanded.ends_with(is_separator) {
            &expanded[..expanded.len() - 1]
        } else {
            expanded.as_str()
        };
        if trimmed.is_empty() {
            return Err(invalid());
        }
        match trimmed.rfind(is_separator) {
            Some(slash) => {
                let name = &trimmed[slash + 1..];
                let dir = &trimmed[..slash];
                if !EstateCatalog::is_valid_name(name) {
                    return Err(invalid());
                }
                // A leading separator alone is the root; a relative pathname
                // is relative to the working directory.
                let base = if dir.is_empty() { PathBuf::from(std::path::MAIN_SEPARATOR.to_string()) } else { PathBuf::from(dir) };
                let base = if base.is_absolute() {
                    normalize(&base)
                } else {
                    normalize(&std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")).join(base))
                };
                Ok(EstateSelector { name: name.to_string(), path: Some(base) })
            }
            None => {
                if !EstateCatalog::is_valid_name(trimmed) {
                    return Err(invalid());
                }
                Ok(EstateSelector { name: trimmed.to_string(), path: None })
            }
        }
    }

    /// `path/name/` when a path was given, none otherwise.
    pub fn directory(&self) -> Option<PathBuf> {
        self.path.as_ref().map(|p| normalize(&p.join(&self.name)))
    }
}

fn is_separator(c: char) -> bool {
    c == '/' || (cfg!(windows) && c == '\\')
}

/// `~` and `~/...` expand to the process home; anything else is unchanged.
fn expand_tilde(value: &str) -> String {
    if value == "~" {
        return identity::process_home().to_string_lossy().into_owned();
    }
    if let Some(rest) = value.strip_prefix("~/") {
        return identity::process_home().join(rest).to_string_lossy().into_owned();
    }
    value.to_string()
}

/// Lexical normalisation: drop `.` components and resolve `..` against the
/// component before it, never touching the filesystem. Twin of Swift's
/// `standardizedFileURL` for the paths the catalog records.
pub(crate) fn normalize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                if !out.pop() {
                    out.push("..");
                }
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

// MARK: - EstateCatalog

/// `estatecatalog.json`. Every path is absolute: the default database location
/// and each estate directory. The configuration directory is never recorded
/// in the file; it is where the file is. An entry's `backend` is optional
/// and absent for SQLite, so a file written before the field existed reads
/// as every estate on SQLite. Field order is alphabetical to match the Swift
/// port's sorted keys.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct CatalogFile {
    #[serde(rename = "defaultLocation")]
    pub(crate) default_location: String,
    pub(crate) estates: Vec<CatalogEntry>,
    pub(crate) version: u32,
}

impl CatalogFile {
    pub(crate) const CURRENT_VERSION: u32 = 1;
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct CatalogEntry {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) backend: Option<EstateBackend>,
    pub(crate) name: String,
    pub(crate) path: String,
}

/// Test seam only: redirects the configuration directory. Not reachable from
/// production code paths; the module's own tests set and clear it under a lock.
static CONFIGURATION_DIRECTORY_OVERRIDE: Mutex<Option<PathBuf>> = Mutex::new(None);

/// Manages `estatecatalog.json`: create, read, update and delete the
/// registry records of estates. Pure storage; it never touches an estate.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EstateCatalog {
    /// The default database location, read from the file. Absolute. Bare
    /// estate names resolve under it. Changed only by `move_default`.
    pub default_location: PathBuf,
    /// The registered estates. Index zero is the active estate.
    records: Vec<EstateRecord>,
}

impl EstateCatalog {
    /// The catalog file name inside the configuration directory.
    pub const FILE_NAME: &'static str = EstateCatalogNames::CATALOG_FILE;
    /// The name of the primary estate, the one `install` registers first.
    pub const DEFAULT_NAME: &'static str = EstateCatalogNames::DEFAULT_ESTATE;

    /// The configuration directory: where `estatecatalog.json` lives, fixed
    /// for the life of the install (`moot_product_identity::storage::
    /// configuration_directory`). Tests redirect it through the module's
    /// private override; nothing else can.
    pub fn configuration_directory() -> PathBuf {
        if let Some(override_dir) = CONFIGURATION_DIRECTORY_OVERRIDE.lock().unwrap().clone() {
            return override_dir;
        }
        identity::configuration_directory()
    }

    /// Test seam: point the configuration directory at a scratch directory
    /// (`None` restores the product identity's). Compiled only for this
    /// crate's tests and for dependants' test builds under `test-seams`; the
    /// override is process-global, so callers serialize their tests on a lock.
    #[cfg(any(test, feature = "test-seams"))]
    pub fn set_configuration_directory_override(dir: Option<PathBuf>) {
        *CONFIGURATION_DIRECTORY_OVERRIDE.lock().unwrap() = dir;
    }

    /// The catalog file: `<configuration>/estatecatalog.json`.
    pub fn catalog_path() -> PathBuf {
        Self::configuration_directory().join(Self::FILE_NAME)
    }

    /// The default database location a fresh install records:
    /// `<configuration>/databases`.
    pub fn initial_default_location() -> PathBuf {
        normalize(&Self::configuration_directory().join(EstateCatalogNames::DATABASES_FOLDER))
    }

    /// The registered estates. Index zero is the active estate.
    pub fn records(&self) -> &[EstateRecord] {
        &self.records
    }

    /// The active estate: index zero.
    pub fn active(&self) -> &EstateRecord {
        &self.records[0]
    }

    /// Where an estate lands when named without a path: `<default location>/<name>`.
    pub fn directory_for_bare_name(&self, name: &str) -> PathBuf {
        normalize(&self.default_location.join(name))
    }

    // MARK: Create and read

    /// First run: create the catalog file recording `<configuration>/databases`
    /// as the default database location and one record, the default estate at
    /// `<default location>/default`. Refuses to overwrite: an existing file is
    /// loaded instead, so calling this twice is harmless.
    pub fn create() -> Result<Self, EstateCatalogError> {
        if Self::catalog_path().exists() {
            return Self::load();
        }
        let location = Self::initial_default_location();
        let catalog = EstateCatalog {
            records: vec![EstateRecord::new(Self::DEFAULT_NAME, location.join(Self::DEFAULT_NAME))],
            default_location: location,
        };
        catalog.save()?;
        Ok(catalog)
    }

    /// Read the catalog file. Fails when it is missing, unreadable, or empty.
    pub fn load() -> Result<Self, EstateCatalogError> {
        let path = Self::catalog_path();
        let unreadable = |detail: String| EstateCatalogError::UnreadableCatalog { path: path.clone(), detail };
        let text = fs::read_to_string(&path).map_err(|e| unreadable(e.to_string()))?;
        let file: CatalogFile = serde_json::from_str(&text).map_err(|e| unreadable(e.to_string()))?;
        if file.version != CatalogFile::CURRENT_VERSION {
            return Err(unreadable(format!("unsupported catalog version {}", file.version)));
        }
        if file.estates.is_empty() {
            return Err(EstateCatalogError::EmptyCatalog { path });
        }
        if !Path::new(&file.default_location).is_absolute() {
            return Err(unreadable("defaultLocation must be an absolute path".to_string()));
        }
        let records = file
            .estates
            .into_iter()
            .map(|entry| {
                EstateRecord::with(entry.name, entry.path, EstateRecordKind::Registered,
                                   entry.backend.unwrap_or(EstateBackend::Sqlite))
            })
            .collect();
        Ok(EstateCatalog { default_location: normalize(Path::new(&file.default_location)), records })
    }

    /// Load the catalog, creating it on first run.
    /// The one call every command uses to find its estate: `open()?.active()`.
    pub fn open() -> Result<Self, EstateCatalogError> {
        if Self::catalog_path().exists() {
            Self::load()
        } else {
            Self::create()
        }
    }

    /// Open the catalog and make `--db <value>` the active estate for this
    /// invocation. A registered name selects its record. An unregistered name
    /// with a path attaches a transient record at `path/name/`. An unregistered
    /// name without a path is refused. Nothing is written.
    pub fn open_selecting(value: &str) -> Result<Self, EstateCatalogError> {
        let mut catalog = Self::open()?;
        let selector = EstateSelector::parse(value)?;
        if selector.path.is_none() {
            if let Some(index) = catalog.records.iter().position(|r| r.name == selector.name) {
                let record = catalog.records.remove(index);
                catalog.records.insert(0, record);
                return Ok(catalog);
            }
        }
        let Some(directory) = selector.directory() else {
            return Err(EstateCatalogError::UnregisteredWithoutPath(value.to_string()));
        };
        let transient = EstateRecord::with(selector.name, directory, EstateRecordKind::Transient, EstateBackend::Sqlite);
        // A manifest left by an earlier run must describe THIS estate, carry
        // no unknown keys, and sit over regular files inside the directory;
        // otherwise the attach is refused before anything opens.
        if transient.manifest_path().exists() {
            Self::read_manifest(&transient)?;
        } else {
            Self::verify_files_stay_inside(&transient)?;
        }
        catalog.records.insert(0, transient);
        Ok(catalog)
    }

    /// The record with this name, if registered.
    pub fn record_named(&self, name: &str) -> Option<&EstateRecord> {
        self.records.iter().find(|r| r.name == name)
    }

    // MARK: Update and delete

    /// Register a new estate at a directory of the caller's choosing and save.
    /// The new record is appended; the active estate is unchanged. A
    /// PostgreSQL estate names its connection string here; its directory
    /// still holds the manifest and the process marker.
    pub fn register(&mut self, name: &str, directory: &Path, backend: EstateBackend) -> Result<(), EstateCatalogError> {
        if !Self::is_valid_name(name) {
            return Err(EstateCatalogError::InvalidName(name.to_string()));
        }
        if self.record_named(name).is_some() {
            return Err(EstateCatalogError::DuplicateName(name.to_string()));
        }
        self.records.push(EstateRecord::with(name, directory, EstateRecordKind::Registered, backend));
        self.save()
    }

    /// Register from the same `<value>` shape `--db` takes: a bare name lands
    /// at `<default location>/<name>/`, a pathname at `path/name/`.
    pub fn register_value(&mut self, value: &str) -> Result<(), EstateCatalogError> {
        let selector = EstateSelector::parse(value)?;
        let directory = selector.directory().unwrap_or_else(|| self.directory_for_bare_name(&selector.name));
        self.register(&selector.name, &directory, EstateBackend::Sqlite)
    }

    /// Change the default database location. When implemented it moves each
    /// `<estatename>/[estate files]` under the old location to
    /// `<new_location>/<estatename>/`, rewrites the affected records and the
    /// recorded default location, and removes the old `databases` directory.
    ///
    /// Not available in this version: refuses without touching anything. The
    /// command that exposes it must run over stdio only and must refuse when
    /// any mootx01 server is running; those gates are the command's.
    pub fn move_default(&mut self, _new_location: &Path) -> Result<(), EstateCatalogError> {
        Err(EstateCatalogError::NotAvailableInThisVersion { operation: "moveDefault".to_string() })
    }

    /// Change where a registered estate's directory is and save. Records
    /// only; the caller is responsible for the estate's files having moved.
    /// The backend is unchanged.
    pub fn relocate(&mut self, name: &str, directory: &Path) -> Result<(), EstateCatalogError> {
        let index = self.index_of(name)?;
        let backend = self.records[index].backend.clone();
        self.records[index] = EstateRecord::with(name, directory, EstateRecordKind::Registered, backend);
        self.save()
    }

    /// Rename a registered estate and save. Its directory does not change.
    pub fn rename(&mut self, name: &str, new_name: &str) -> Result<(), EstateCatalogError> {
        if !Self::is_valid_name(new_name) {
            return Err(EstateCatalogError::InvalidName(new_name.to_string()));
        }
        let index = self.index_of(name)?;
        if new_name != name && self.record_named(new_name).is_some() {
            return Err(EstateCatalogError::DuplicateName(new_name.to_string()));
        }
        let old = &self.records[index];
        self.records[index] = EstateRecord::with(new_name, old.directory.clone(), EstateRecordKind::Registered, old.backend.clone());
        self.save()
    }

    /// Make a registered estate the active one, moving it to index zero, and save.
    pub fn activate(&mut self, name: &str) -> Result<(), EstateCatalogError> {
        let index = self.index_of(name)?;
        let record = self.records.remove(index);
        self.records.insert(0, record);
        self.save()
    }

    /// Remove a registered estate from the catalog and save. Never touches the
    /// estate's files. The active estate cannot be removed.
    pub fn remove(&mut self, name: &str) -> Result<(), EstateCatalogError> {
        let index = self.index_of(name)?;
        if index == 0 {
            return Err(EstateCatalogError::CannotRemoveActive(name.to_string()));
        }
        self.records.remove(index);
        self.save()
    }

    fn index_of(&self, name: &str) -> Result<usize, EstateCatalogError> {
        self.records
            .iter()
            .position(|r| r.name == name)
            .ok_or_else(|| EstateCatalogError::UnknownName(name.to_string()))
    }

    // MARK: Per-estate manifest

    /// Read `estate.json` from the record's directory. Refuses a file whose
    /// name does not match the record: a directory renamed by hand is not
    /// silently adopted under a new name.
    pub fn read_manifest(record: &EstateRecord) -> Result<EstateManifest, EstateCatalogError> {
        let path = record.manifest_path();
        let unreadable = |detail: String| EstateCatalogError::UnreadableEstateManifest { path: path.clone(), detail };
        let text = fs::read_to_string(&path).map_err(|e| unreadable(e.to_string()))?;
        // Strict shape: every top-level key must be one this version knows. A
        // path, a redirect or any unknown field could hide a rogue database
        // under a manifest that looks right.
        let object: BTreeMap<String, serde_json::Value> =
            serde_json::from_str(&text).map_err(|_| unreadable("not a JSON object".to_string()))?;
        let unknown: Vec<&str> = object
            .keys()
            .map(String::as_str)
            .filter(|k| !EstateManifest::ALLOWED_KEYS.contains(k))
            .collect();
        if !unknown.is_empty() {
            return Err(unreadable(format!(
                "unknown keys {unknown:?}; a manifest may not carry paths or redirects"
            )));
        }
        let manifest: EstateManifest = serde_json::from_str(&text).map_err(|e| unreadable(e.to_string()))?;
        if manifest.file_version != EstateManifest::CURRENT_FILE_VERSION {
            return Err(unreadable(format!("unsupported estate.json version {}", manifest.file_version)));
        }
        if manifest.name != record.name {
            return Err(unreadable(format!(
                "names estate '{}' but the directory is '{}'", manifest.name, record.name
            )));
        }
        Self::verify_files_stay_inside(record)?;
        Ok(manifest)
    }

    /// Every estate file that exists must be a regular file inside the estate
    /// directory. A symbolic link among them would let a manifest that looks
    /// right front for a database somewhere else; it is refused.
    pub fn verify_files_stay_inside(record: &EstateRecord) -> Result<(), EstateCatalogError> {
        let directory = resolve(&record.directory);
        for file in record.owned_file_paths() {
            let Ok(metadata) = fs::symlink_metadata(&file) else { continue };
            let file_name = file.file_name().unwrap_or_default().to_string_lossy().into_owned();
            if metadata.file_type().is_symlink() {
                return Err(EstateCatalogError::UnreadableEstateManifest {
                    path: record.manifest_path(),
                    detail: format!(
                        "{file_name} is a symbolic link; estate files must be regular files in {}",
                        record.directory.display()
                    ),
                });
            }
            if !resolve(&file).starts_with(&directory) {
                return Err(EstateCatalogError::UnreadableEstateManifest {
                    path: record.manifest_path(),
                    detail: format!("{file_name} resolves outside the estate directory"),
                });
            }
        }
        Ok(())
    }

    /// Write `estate.json` into the record's directory, atomically, creating
    /// the directory if needed. The one file the catalog writes inside an
    /// estate; it is the manifest, not estate content.
    pub fn write_manifest(manifest: &EstateManifest, record: &EstateRecord) -> Result<(), EstateCatalogError> {
        let path = record.manifest_path();
        if manifest.name != record.name {
            return Err(EstateCatalogError::UnreadableEstateManifest {
                path,
                detail: format!("configuration names '{}' but the record is '{}'", manifest.name, record.name),
            });
        }
        let write = || -> io::Result<()> {
            let text = serde_json::to_string_pretty(manifest).map_err(io::Error::other)?;
            fs::create_dir_all(&record.directory)?;
            write_atomically(&path, text.as_bytes())
        };
        write().map_err(|e| EstateCatalogError::UnwritableCatalog { path: record.manifest_path(), detail: e.to_string() })
    }

    /// An estate name is one path component: non-empty, not `.` or `..`,
    /// and free of path separators.
    pub fn is_valid_name(name: &str) -> bool {
        !name.is_empty() && name != "." && name != ".." && !name.contains('/') && !name.contains('\\')
    }

    /// Write the catalog file atomically from the current records.
    fn save(&self) -> Result<(), EstateCatalogError> {
        let path = Self::catalog_path();
        // Transient records never reach the file.
        let file = CatalogFile {
            default_location: self.default_location.to_string_lossy().into_owned(),
            estates: self
                .records
                .iter()
                .filter(|r| r.kind == EstateRecordKind::Registered)
                .map(|r| CatalogEntry {
                    backend: match &r.backend {
                        EstateBackend::Sqlite => None,
                        other => Some(other.clone()),
                    },
                    name: r.name.clone(),
                    path: r.directory.to_string_lossy().into_owned(),
                })
                .collect(),
            version: CatalogFile::CURRENT_VERSION,
        };
        let write = || -> io::Result<()> {
            let text = serde_json::to_string_pretty(&file).map_err(io::Error::other)?;
            fs::create_dir_all(Self::configuration_directory())?;
            write_atomically(&path, text.as_bytes())
        };
        write().map_err(|e| EstateCatalogError::UnwritableCatalog { path: Self::catalog_path(), detail: e.to_string() })
    }
}

/// The path with symbolic links resolved when it exists, normalised as given
/// when it does not (a transient attach may name a directory not yet created).
fn resolve(path: &Path) -> PathBuf {
    fs::canonicalize(path).unwrap_or_else(|_| normalize(path))
}

/// Write through a sibling temporary file and rename it into place, so a
/// reader never sees a torn file.
fn write_atomically(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let file_name = path.file_name().unwrap_or_default().to_string_lossy().into_owned();
    let temporary = path.with_file_name(format!(".{file_name}.{}.tmp", std::process::id()));
    fs::write(&temporary, bytes)?;
    fs::rename(&temporary, path)
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    // Mirrors Tests/GeniusLocusKitTests/EstateCatalogTests.swift, one test per
    // Swift test in the same order. The tests share the configuration
    // directory override, so each holds `TEST_LOCK` for its duration.

    use super::*;
    use std::sync::MutexGuard;

    static TEST_LOCK: Mutex<()> = Mutex::new(());

    struct Scratch {
        dir: PathBuf,
        _guard: MutexGuard<'static, ()>,
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            *CONFIGURATION_DIRECTORY_OVERRIDE.lock().unwrap() = None;
            let _ = fs::remove_dir_all(&self.dir);
        }
    }

    fn scratch_dir() -> PathBuf {
        let dir = normalize(&std::env::temp_dir().join(format!("estate-catalog-{}", uuid::Uuid::new_v4())));
        fs::create_dir_all(&dir).unwrap();
        fs::canonicalize(&dir).unwrap()
    }

    /// Point the catalog's configuration directory at a scratch directory for one test.
    fn configuration() -> Scratch {
        let guard = TEST_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let dir = scratch_dir();
        *CONFIGURATION_DIRECTORY_OVERRIDE.lock().unwrap() = Some(dir.clone());
        Scratch { dir, _guard: guard }
    }

    fn file() -> CatalogFile {
        serde_json::from_str(&fs::read_to_string(EstateCatalog::catalog_path()).unwrap()).unwrap()
    }

    fn names(catalog: &EstateCatalog) -> Vec<&str> {
        catalog.records().iter().map(|r| r.name.as_str()).collect()
    }

    fn path_string(path: &Path) -> String {
        path.to_string_lossy().into_owned()
    }

    fn sample_manifest_json(name: &str, extra: &str) -> String {
        format!(
            r#"{{"fileVersion":1,"name":"{name}","schemaVersion":1,"formatVersion":{{"major":1,"minor":7}},"encryption":"plaintext","created":"2026-09-08T00:00:00Z"{extra}}}"#
        )
    }

    #[test]
    fn create_writes_the_default_record_and_is_idempotent() {
        let s = configuration();
        let catalog = EstateCatalog::create().unwrap();
        assert_eq!(catalog.records().len(), 1);
        assert_eq!(catalog.active().name, "default");
        assert_eq!(catalog.default_location, s.dir.join("databases"));
        assert_eq!(catalog.active().directory, catalog.directory_for_bare_name("default"));
        let on_disk = file();
        assert_eq!(on_disk.default_location, path_string(&s.dir.join("databases")));
        assert_eq!(on_disk.estates, vec![CatalogEntry {
            backend: None, name: "default".into(), path: path_string(&s.dir.join("databases/default")),
        }]);
        let mut again = EstateCatalog::create().unwrap();
        assert_eq!(again, catalog);
        again.register("extra", &s.dir.join("databases/extra"), EstateBackend::Sqlite).unwrap();
        assert_eq!(EstateCatalog::create().unwrap().records().len(), 2); // did not overwrite
    }

    #[test]
    fn platform_directory_is_the_identity_rule() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        *CONFIGURATION_DIRECTORY_OVERRIDE.lock().unwrap() = None;
        let expected = identity::configuration_directory();
        assert_eq!(EstateCatalog::configuration_directory(), expected);
        assert_eq!(EstateCatalog::catalog_path().file_name().unwrap(), "estatecatalog.json");
        assert_eq!(EstateCatalog::initial_default_location(), normalize(&expected.join("databases")));
    }

    #[test]
    fn open_creates_when_absent_and_loads_when_present() {
        let s = configuration();
        assert_eq!(EstateCatalog::configuration_directory(), s.dir);
        assert_eq!(EstateCatalog::catalog_path(), s.dir.join("estatecatalog.json"));
        assert!(!EstateCatalog::catalog_path().exists());
        let first = EstateCatalog::open().unwrap();
        assert_eq!(first.active().name, "default");
        assert_eq!(EstateCatalog::open().unwrap(), first);
    }

    #[test]
    fn load_reads_the_default_location_and_absolute_paths() {
        let s = configuration();
        let external = scratch_dir();
        let json = format!(
            r#"{{"version": 1, "defaultLocation": "{base}/databases", "estates": [
              {{"name": "research", "path": "{external}"}},
              {{"name": "default", "path": "{base}/databases/default"}}
            ]}}"#,
            base = path_string(&s.dir), external = path_string(&external)
        );
        fs::write(EstateCatalog::catalog_path(), json).unwrap();
        let catalog = EstateCatalog::load().unwrap();
        assert_eq!(names(&catalog), ["research", "default"]);
        assert_eq!(catalog.active().name, "research"); // index zero is active, whatever its name
        assert_eq!(catalog.active().directory, external);
        assert_eq!(catalog.default_location, s.dir.join("databases"));
        assert_eq!(catalog.record_named("default").unwrap().directory, s.dir.join("databases/default"));
        assert_eq!(catalog.directory_for_bare_name("x"), s.dir.join("databases/x"));
        assert!(catalog.record_named("nope").is_none());
        let _ = fs::remove_dir_all(external);
    }

    #[test]
    fn load_refuses_missing_unreadable_and_empty() {
        let s = configuration();
        let path = EstateCatalog::catalog_path();
        let unreadable = |r: Result<EstateCatalog, EstateCatalogError>| matches!(r, Err(EstateCatalogError::UnreadableCatalog { .. }));
        assert!(unreadable(EstateCatalog::load()), "missing file");
        fs::write(&path, "not json").unwrap();
        assert!(unreadable(EstateCatalog::load()), "bad json");
        fs::write(&path, r#"{"version": 1, "defaultLocation": "/d", "estates": []}"#).unwrap();
        assert_eq!(EstateCatalog::load(), Err(EstateCatalogError::EmptyCatalog { path: path.clone() }));
        fs::write(&path, r#"{"version": 1, "defaultLocation": "relative/x", "estates": [{"name": "default", "path": "/x"}]}"#).unwrap();
        assert!(unreadable(EstateCatalog::load()), "relative default");
        fs::write(&path, r#"{"version": 99, "defaultLocation": "/d", "estates": [{"name": "default", "path": "/x"}]}"#).unwrap();
        assert!(unreadable(EstateCatalog::load()), "version");
        drop(s);
    }

    #[test]
    fn register_appends_and_saves() {
        let s = configuration();
        let mut catalog = EstateCatalog::create().unwrap();
        let external = PathBuf::from("/Volumes/work/moot/research");
        catalog.register("research", &external, EstateBackend::Sqlite).unwrap();
        assert_eq!(names(&catalog), ["default", "research"]);
        assert_eq!(catalog.active().name, "default");
        assert_eq!(file().estates, vec![
            CatalogEntry { backend: None, name: "default".into(), path: path_string(&catalog.directory_for_bare_name("default")) },
            CatalogEntry { backend: None, name: "research".into(), path: "/Volumes/work/moot/research".into() },
        ]);
        assert_eq!(EstateCatalog::load().unwrap(), catalog);
        assert_eq!(catalog.register("research", &external, EstateBackend::Sqlite),
                   Err(EstateCatalogError::DuplicateName("research".into())));
        for bad in ["", ".", "..", "a/b", "a\\b"] {
            assert_eq!(catalog.register(bad, &external, EstateBackend::Sqlite),
                       Err(EstateCatalogError::InvalidName(bad.into())));
        }
        assert_eq!(catalog.records().len(), 2);
        drop(s);
    }

    #[test]
    fn relocate_rename_activate_remove_each_save() {
        let s = configuration();
        let mut catalog = EstateCatalog::create().unwrap();
        catalog.register("research", &s.dir.join("databases/research"), EstateBackend::Sqlite).unwrap();

        let moved = PathBuf::from("/Volumes/big/research");
        catalog.relocate("research", &moved).unwrap();
        assert_eq!(EstateCatalog::load().unwrap().record_named("research").unwrap().directory, moved);
        assert_eq!(catalog.relocate("nope", &moved), Err(EstateCatalogError::UnknownName("nope".into())));

        catalog.rename("research", "lab").unwrap();
        assert_eq!(names(&EstateCatalog::load().unwrap()), ["default", "lab"]);
        assert_eq!(catalog.record_named("lab").unwrap().directory, moved);
        assert_eq!(catalog.rename("lab", "default"), Err(EstateCatalogError::DuplicateName("default".into())));
        assert_eq!(catalog.rename("lab", "a/b"), Err(EstateCatalogError::InvalidName("a/b".into())));
        assert_eq!(catalog.rename("nope", "x"), Err(EstateCatalogError::UnknownName("nope".into())));

        catalog.activate("lab").unwrap();
        assert_eq!(EstateCatalog::load().unwrap().active().name, "lab");
        assert_eq!(names(&catalog), ["lab", "default"]);
        assert_eq!(catalog.activate("nope"), Err(EstateCatalogError::UnknownName("nope".into())));

        catalog.remove("default").unwrap();
        assert_eq!(names(&EstateCatalog::load().unwrap()), ["lab"]);
        assert_eq!(catalog.remove("default"), Err(EstateCatalogError::UnknownName("default".into())));
    }

    #[test]
    fn remove_refuses_the_active_record() {
        let _s = configuration();
        let mut catalog = EstateCatalog::create().unwrap();
        assert_eq!(catalog.remove("default"), Err(EstateCatalogError::CannotRemoveActive("default".into())));
        assert_eq!(catalog.records().len(), 1);
    }

    #[test]
    fn record_spells_every_owned_file() {
        let dir = PathBuf::from("/tmp/x/databases/default");
        let record = EstateRecord::new("default", &dir);
        let names: Vec<String> = record.owned_file_paths().iter()
            .map(|p| p.file_name().unwrap().to_string_lossy().into_owned()).collect();
        assert_eq!(names, [
            "estate.json", "estate.pid",
            "estate.sqlite", "estate.sqlite-wal", "estate.sqlite-shm",
            "estate.queue.sqlite", "estate.queue.sqlite-wal", "estate.queue.sqlite-shm",
            "estate.vectors.vec", "encode.drain.lease",
        ]);
        assert_eq!(record.legacy_encryption_opt_out_path().file_name().unwrap(), "no-encrypt");
        assert_eq!(EstateCatalogNames::CATALOG_FILE, "estatecatalog.json");
        assert_eq!(EstateCatalogNames::DATABASES_FOLDER, "databases");
        assert_eq!(EstateCatalogNames::DEFAULT_ESTATE, "default");
        assert!(record.owned_file_paths().iter().all(|p| p.parent().unwrap() == dir));
    }

    #[test]
    fn selector_splits_value_into_path_and_name() {
        let bare = EstateSelector::parse("research").unwrap();
        assert!(bare.name == "research" && bare.path.is_none() && bare.directory().is_none());
        let abs = EstateSelector::parse("/Volumes/big/research").unwrap();
        assert_eq!(abs.name, "research");
        assert_eq!(abs.path, Some(PathBuf::from("/Volumes/big")));
        assert_eq!(abs.directory(), Some(PathBuf::from("/Volumes/big/research")));
        let rel = EstateSelector::parse("sets/estate_set1/u7").unwrap();
        let cwd = std::env::current_dir().unwrap();
        assert_eq!(rel.directory(), Some(normalize(&cwd.join("sets/estate_set1/u7"))));
        let trailing = EstateSelector::parse("/Volumes/big/research/").unwrap();
        assert_eq!(trailing, abs);
        let home = EstateSelector::parse("~/moot/x").unwrap();
        let home_dir = home.directory().unwrap();
        assert!(home_dir.ends_with("moot/x") && home_dir.is_absolute());
        for bad in ["", "/", "a/..", "./."] {
            assert_eq!(EstateSelector::parse(bad), Err(EstateCatalogError::InvalidName(bad.into())));
        }
    }

    #[test]
    fn db_value_selects_registered_or_attaches_transient() {
        let s = configuration();
        let mut catalog = EstateCatalog::create().unwrap();
        catalog.register("research", Path::new("/Volumes/big/research"), EstateBackend::Sqlite).unwrap();

        // Registered name: selected, made active, kind registered.
        let by_name = EstateCatalog::open_selecting("research").unwrap();
        assert!(by_name.active().name == "research" && by_name.active().kind == EstateRecordKind::Registered);
        assert_eq!(names(&by_name), ["research", "default"]);

        // Unregistered with a path: transient attach at path/name, active, not saved.
        let attached = EstateCatalog::open_selecting("/Volumes/tmp/scratch7").unwrap();
        assert_eq!(*attached.active(), EstateRecord::with("scratch7", "/Volumes/tmp/scratch7",
                                                          EstateRecordKind::Transient, EstateBackend::Sqlite));
        assert_eq!(attached.records().len(), 3);
        assert_eq!(EstateCatalog::load().unwrap().records().len(), 2);

        // A mutation while a transient is active still never writes it.
        let mut live = attached.clone();
        live.register("another", &s.dir.join("databases/another"), EstateBackend::Sqlite).unwrap();
        assert_eq!(names(&EstateCatalog::load().unwrap()), ["default", "research", "another"]);

        // Unregistered without a path: format error.
        assert_eq!(EstateCatalog::open_selecting("nowhere").err(),
                   Some(EstateCatalogError::UnregisteredWithoutPath("nowhere".into())));
        // Explicit path wins even when the name is registered: transient at that path.
        let explicit = EstateCatalog::open_selecting("/elsewhere/research").unwrap();
        assert_eq!(explicit.active().kind, EstateRecordKind::Transient);
        assert_eq!(explicit.active().directory, PathBuf::from("/elsewhere/research"));
        // The selector argument re-selects the same record in a child process.
        assert_eq!(by_name.active().selector_argument(), "research");
        assert_eq!(attached.active().selector_argument(), "/Volumes/tmp/scratch7");
        assert_eq!(EstateCatalog::open_selecting(&attached.active().selector_argument()).unwrap().active(),
                   attached.active());
    }

    #[test]
    fn register_from_value_lands_where_db_would_look() {
        let s = configuration();
        let mut catalog = EstateCatalog::create().unwrap();
        catalog.register_value("research").unwrap();
        assert_eq!(catalog.record_named("research").unwrap().directory, catalog.directory_for_bare_name("research"));
        assert_eq!(catalog.record_named("research").unwrap().directory, s.dir.join("databases/research"));
        catalog.register_value("/Volumes/big/lab").unwrap();
        assert_eq!(catalog.record_named("lab").unwrap().directory, PathBuf::from("/Volumes/big/lab"));
        assert_eq!(EstateCatalog::open_selecting("lab").unwrap().active().kind, EstateRecordKind::Registered);
        assert_eq!(catalog.register_value("/other/lab"), Err(EstateCatalogError::DuplicateName("lab".into())));
    }

    #[test]
    fn move_default_refuses_in_this_version() {
        let _s = configuration();
        let mut catalog = EstateCatalog::create().unwrap();
        let before = file();
        assert_eq!(catalog.move_default(Path::new("/Volumes/big/moot")),
                   Err(EstateCatalogError::NotAvailableInThisVersion { operation: "moveDefault".into() }));
        assert_eq!(file(), before);
        assert_eq!(catalog.default_location, EstateCatalog::initial_default_location());
    }

    #[test]
    fn estate_manifest_round_trips_inside_the_estate_directory() {
        let s = configuration();
        let record = EstateRecord::with("barnone", s.dir.join("foo/bar/barnone"), EstateRecordKind::Transient, EstateBackend::Sqlite);
        let written = EstateManifest::new("barnone", 44, EstateFormatVersion::CURRENT,
                                          EstateManifestEncryption::Plaintext, "2026-09-08T00:00:00Z");
        EstateCatalog::write_manifest(&written, &record).unwrap();
        assert!(record.manifest_path().exists());
        assert!(record.manifest_path().ends_with("foo/bar/barnone/estate.json"));
        let read = EstateCatalog::read_manifest(&record).unwrap();
        assert_eq!(read, written);
        assert_eq!(read.file_version, EstateManifest::CURRENT_FILE_VERSION);
        assert_eq!(read.format_version, EstateFormatVersion::V1_7);
        // The file carries the shared shape: sorted keys, formatVersion as an object.
        let text = fs::read_to_string(record.manifest_path()).unwrap();
        let value: serde_json::Value = serde_json::from_str(&text).unwrap();
        assert_eq!(value["formatVersion"], serde_json::json!({"major": 1, "minor": 7}));
        let keys: Vec<&str> = value.as_object().unwrap().keys().map(String::as_str).collect();
        assert_eq!(keys, ["created", "encryption", "fileVersion", "formatVersion", "name", "schemaVersion"]);
        // Nothing else appears in the estate directory or its parent.
        let entries = |p: &Path| -> Vec<String> {
            fs::read_dir(p).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect()
        };
        assert_eq!(entries(&record.directory), ["estate.json"]);
        assert_eq!(entries(record.directory.parent().unwrap()), ["barnone"]);
    }

    #[test]
    fn estate_manifest_refuses_missing_foreign_and_renamed() {
        let s = configuration();
        let record = EstateRecord::new("a", s.dir.join("a"));
        let refused = |r: Result<EstateManifest, EstateCatalogError>| matches!(r, Err(EstateCatalogError::UnreadableEstateManifest { .. }));
        assert!(refused(EstateCatalog::read_manifest(&record)), "missing");
        let cfg = EstateManifest::new("a", 1, EstateFormatVersion::CURRENT, EstateManifestEncryption::Encrypted, "2026-09-08T00:00:00Z");
        EstateCatalog::write_manifest(&cfg, &record).unwrap();
        let renamed = EstateRecord::new("b", &record.directory);
        assert!(refused(EstateCatalog::read_manifest(&renamed)), "renamed");
        assert!(matches!(EstateCatalog::write_manifest(&cfg, &renamed),
                         Err(EstateCatalogError::UnreadableEstateManifest { .. })), "foreign write");
    }

    #[cfg(unix)]
    #[test]
    fn transient_attach_refuses_a_rogue_manifest() {
        let s = configuration();
        EstateCatalog::create().unwrap();
        let dir = s.dir.join("tmp/scratch");
        fs::create_dir_all(&dir).unwrap();
        let manifest = dir.join("estate.json");
        let dir_value = path_string(&dir);
        let refused = |r: Result<EstateCatalog, EstateCatalogError>, needle: &str| match r {
            Err(EstateCatalogError::UnreadableEstateManifest { detail, .. }) => detail.contains(needle),
            _ => false,
        };

        // A manifest for a different estate: refused.
        fs::write(&manifest, sample_manifest_json("other", "")).unwrap();
        assert!(refused(EstateCatalog::open_selecting(&dir_value), "other"));
        // The right name but an extra key that could redirect: refused.
        fs::write(&manifest, sample_manifest_json("scratch", r#","path":"/elsewhere""#)).unwrap();
        assert!(refused(EstateCatalog::open_selecting(&dir_value), "path"));
        // A correct manifest: attached.
        fs::write(&manifest, sample_manifest_json("scratch", "")).unwrap();
        assert_eq!(EstateCatalog::open_selecting(&dir_value).unwrap().active().name, "scratch");
        // A database that is a symlink to somewhere else: refused, manifest or not.
        let elsewhere = s.dir.join("elsewhere.sqlite");
        fs::write(&elsewhere, "x").unwrap();
        std::os::unix::fs::symlink(&elsewhere, dir.join("estate.sqlite")).unwrap();
        assert!(refused(EstateCatalog::open_selecting(&dir_value), "symbolic link"));
        fs::remove_file(&manifest).unwrap();
        assert!(refused(EstateCatalog::open_selecting(&dir_value), "symbolic link"));
    }

    #[test]
    fn backend_round_trips_and_defaults_to_sqlite() {
        let s = configuration();
        let mut catalog = EstateCatalog::create().unwrap();
        assert_eq!(catalog.active().backend, EstateBackend::Sqlite);
        let connection = "postgresql://moot@db.example/estates";
        let pg = EstateBackend::Postgresql { connection_string: connection.into() };
        catalog.register("pg", &s.dir.join("databases/pg"), pg.clone()).unwrap();
        // The file spells the backend only when it is not SQLite; the default record has no field.
        let entries = file().estates;
        assert_eq!(entries[0].backend, None);
        assert_eq!(entries[1].backend, Some(pg.clone()));
        let text = fs::read_to_string(EstateCatalog::catalog_path()).unwrap();
        assert!(text.contains(r#""kind": "postgresql""#));
        assert!(text.contains(r#""connectionString": "postgresql://moot@db.example/estates""#));
        // Reload, rename and relocate keep the backend.
        let mut loaded = EstateCatalog::load().unwrap();
        assert_eq!(loaded.record_named("pg").unwrap().backend, pg);
        loaded.rename("pg", "warehouse").unwrap();
        loaded.relocate("warehouse", &s.dir.join("elsewhere/warehouse")).unwrap();
        assert_eq!(EstateCatalog::load().unwrap().record_named("warehouse").unwrap().backend, pg);
        // A transient attach is always SQLite.
        let dir = scratch_dir();
        assert_eq!(EstateCatalog::open_selecting(&path_string(&dir)).unwrap().active().backend, EstateBackend::Sqlite);
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn load_refuses_a_malformed_backend_entry() {
        let _s = configuration();
        let path = EstateCatalog::catalog_path();
        for entry in [
            r#"{"name": "default", "path": "/x", "backend": {"kind": "postgresql"}}"#,
            r#"{"name": "default", "path": "/x", "backend": {"kind": "postgresql", "connectionString": ""}}"#,
            r#"{"name": "default", "path": "/x", "backend": {"kind": "sqlite", "connectionString": "postgresql://h/d"}}"#,
            r#"{"name": "default", "path": "/x", "backend": {"kind": "oracle"}}"#,
        ] {
            fs::write(&path, format!(r#"{{"version": 1, "defaultLocation": "/d", "estates": [{entry}]}}"#)).unwrap();
            assert!(matches!(EstateCatalog::load(), Err(EstateCatalogError::UnreadableCatalog { .. })), "{entry}");
        }
        // The explicit SQLite spelling is accepted.
        fs::write(&path, r#"{"version": 1, "defaultLocation": "/d", "estates": [{"name": "default", "path": "/x", "backend": {"kind": "sqlite"}}]}"#).unwrap();
        assert_eq!(EstateCatalog::load().unwrap().active().backend, EstateBackend::Sqlite);
    }

    #[test]
    fn the_catalog_never_touches_estate_files() {
        let s = configuration();
        let mut catalog = EstateCatalog::create().unwrap();
        catalog.register("r", &s.dir.join("databases/r"), EstateBackend::Sqlite).unwrap();
        catalog.relocate("r", &s.dir.join("elsewhere/r")).unwrap();
        catalog.activate("r").unwrap();
        catalog.remove("default").unwrap();
        // Only estatecatalog.json exists under the configuration directory: no databases/, no elsewhere/.
        let contents: Vec<String> = fs::read_dir(&s.dir).unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
        assert_eq!(contents, [EstateCatalog::FILE_NAME]);
    }
}
