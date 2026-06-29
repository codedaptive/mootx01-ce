//! core/service.rs — service-manager backends (spec §6).
//!
//! Pure generators (input → file content string) so the unit contract is
//! testable on any platform; the register/unregister wiring shells out to
//! the platform service manager and is runtime-guarded.
//!
//! Linux: per-user systemd units `~/.config/systemd/user/mootx01.service`
//! and `mootx01-mgr.service`, `systemctl --user enable --now`,
//! `Restart=on-failure`, `loginctl enable-linger` (best-effort) so the
//! daemon starts without an open session. Non-systemd hosts get the unit
//! text + manual instructions printed instead (spec §6: no sysvinit/openrc
//! in v1).
//!
//! Windows: per-user Task Scheduler logon tasks `mootx01` and `mootx01-mgr`
//! registered via PowerShell COM cmdlets (schtasks.exe denies ONLOGON triggers
//! to non-admins; COM permits user-scoped triggers without elevation). Task Scheduler has no per-task
//! environment block, so non-secret task environment values run through a
//! `cmd /c "set …&& …"` wrapper when needed. The mgr control token is kept
//! out of task metadata and loaded by moot-mgr from its user-local token file.
//! SCM services are out of scope for v1 (spec §6). macOS is Swift territory
//! (launchd, LaunchAgent.swift).

use std::path::{Path, PathBuf};
use std::process::Command;

/// §6 unit names (plain conventional names — no reverse-DNS off Apple).
pub const DAEMON_UNIT: &str = "mootx01.service";
pub const MGR_UNIT: &str = "mootx01-mgr.service";

/// §6 Windows Task Scheduler task names.
pub const DAEMON_TASK: &str = "mootx01";
pub const MGR_TASK: &str = "mootx01-mgr";

// ---------------------------------------------------------------------------
// Path-safety validators — fail CLOSED before interpolation
// ---------------------------------------------------------------------------

/// Returns `true` when the string can be safely embedded in a Windows
/// `cmd.exe` command string of the form `cmd /c "set VAR=VALUE&& ..."`.
/// cmd.exe interprets `&`, `|`, `<`, `>`, `^`, `%`, `"`, `;`, and
/// CR/LF as command operators or string terminators. No legitimate Windows
/// data-directory path contains these characters; an attacker who can set
/// MOOTX01_DATA_DIR to an adversarial value would be able to inject
/// arbitrary cmd.exe commands without this gate.
pub fn is_cmd_safe(s: &str) -> bool {
    !s.chars()
        .any(|c| matches!(c, '&' | '|' | '<' | '>' | '^' | '%' | '"' | ';' | '\n' | '\r'))
}

/// Returns `true` when the string can be safely embedded in a systemd
/// `Environment=` directive. A newline terminates the directive and allows
/// a following line to be injected as a new stanza (e.g. `ExecStart=`).
/// No legitimate Linux data-directory path contains CR or LF; this gate
/// closes the injection window from a crafted MOOTX01_DATA_DIR value.
pub fn is_systemd_safe(s: &str) -> bool {
    !s.contains('\n') && !s.contains('\r')
}

// ---------------------------------------------------------------------------
// Windows Task Scheduler backend
// ---------------------------------------------------------------------------

/// The logon-task action for the daemon: (execute, argument). Always uses a
/// `cmd /c "set …&& …"` wrapper to bake `MOOTX01_VAULT` (and optionally
/// `MOOTX01_DATA_DIR`) into the task since Task Scheduler has no per-task
/// environment block. `vault_on` governs `MOOTX01_VAULT`: true → "1"
/// (vault surface enabled), false → "0" (vault surface hidden) per ADR-015.
///
/// Returns `Err` when `data_dir_override` contains characters that would
/// allow cmd.exe command injection (planned hardening — fails CLOSED).
pub fn daemon_task_command(
    binary_path: &str,
    data_dir_override: Option<&str>,
    vault_on: bool,
) -> Result<(String, String), String> {
    if let Some(d) = data_dir_override {
        if !is_cmd_safe(d) {
            return Err(format!(
                "MOOTX01_DATA_DIR value contains characters unsafe for cmd.exe interpolation: {d:?}"
            ));
        }
    }
    let vault_val = if vault_on { "1" } else { "0" };
    // We always bake MOOTX01_VAULT so the daemon starts with the right
    // vault posture regardless of the parent shell's environment.
    let data_set = data_dir_override
        .map(|d| format!("set MOOTX01_DATA_DIR={d}&& "))
        .unwrap_or_default();
    Ok((
        "cmd.exe".to_string(),
        format!("/c \"{data_set}set MOOTX01_VAULT={vault_val}&& \"{binary_path}\" serve --http auto\""),
    ))
}

/// The logon-task action for the mgr: (execute, argument). The bearer token is
/// intentionally not embedded in the action; moot-mgr reads it from the
/// user-local token file written during Windows install. A cmd wrapper is used
/// only when a non-secret data-dir override must be supplied.
///
/// Returns `Err` when `data_dir_override` contains characters that would
/// allow cmd.exe command injection (planned hardening — fails CLOSED).
pub fn mgr_task_command(
    mgr_binary_path: &str,
    _control_token: &str,
    data_dir_override: Option<&str>,
) -> Result<(String, String), String> {
    match data_dir_override {
        Some(d) => {
            if !is_cmd_safe(d) {
                return Err(format!(
                    "MOOTX01_DATA_DIR value contains characters unsafe for cmd.exe interpolation: {d:?}"
                ));
            }
            Ok((
                "cmd.exe".to_string(),
                format!("/c \"set MOOTX01_DATA_DIR={d}&& \"{mgr_binary_path}\" serve\""),
            ))
        }
        None => Ok((mgr_binary_path.to_string(), "serve".to_string())),
    }
}

#[cfg(target_os = "windows")]
pub fn mgr_control_token_file() -> PathBuf {
    let base = std::env::var("LOCALAPPDATA")
        .map(PathBuf::from)
        .or_else(|_| std::env::var("USERPROFILE").map(|h| PathBuf::from(h).join("AppData").join("Local")))
        .unwrap_or_else(|_| PathBuf::from("."));
    base.join("com.mootx01.ce").join("moot-mgr").join("control.token")
}

#[cfg(target_os = "windows")]
pub fn write_mgr_control_token(token: &str) -> Result<PathBuf, String> {
    let path = mgr_control_token_file();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("create {}: {e}", parent.display()))?;
    }
    std::fs::write(&path, format!("{token}\n")).map_err(|e| format!("write {}: {e}", path.display()))?;
    Ok(path)
}

/// Single-quote a string for embedding in a PowerShell -Command (single
/// quotes double inside single-quoted PS strings).
#[cfg(target_os = "windows")]
fn ps_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "''"))
}

/// Run a PowerShell command non-interactively, capturing stdout.
#[cfg(target_os = "windows")]
fn powershell(command: &str) -> Result<String, String> {
    match Command::new("powershell")
        .args(["-NoProfile", "-NonInteractive", "-Command", command])
        .output()
    {
        Ok(o) if o.status.success() => Ok(String::from_utf8_lossy(&o.stdout).trim().to_string()),
        Ok(o) => Err(String::from_utf8_lossy(&o.stderr).trim().to_string()),
        Err(e) => Err(format!("cannot run powershell: {e}")),
    }
}

/// Create (or replace) a per-user logon task and start it now — the
/// `enable --now` equivalent. Uses the Task Scheduler COM API via
/// PowerShell cmdlets: schtasks.exe denies ONLOGON triggers to non-admins,
/// but the COM API permits user-scoped logon triggers without elevation
/// (verified live; keeps the install elevation-free like launchd agents and
/// systemd --user).
#[cfg(target_os = "windows")]
pub fn register_task(task_name: &str, execute: &str, argument: &str) -> RegisterOutcome {
    let cmd = format!(
        "$t = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME; \
         $a = New-ScheduledTaskAction -Execute {exe} -Argument {arg}; \
         Register-ScheduledTask -TaskName {name} -Trigger $t -Action $a -Force | Out-Null; \
         Start-ScheduledTask -TaskName {name}",
        exe = ps_quote(execute),
        arg = ps_quote(argument),
        name = ps_quote(task_name),
    );
    match powershell(&cmd) {
        Ok(_) => RegisterOutcome::Registered(PathBuf::from(format!("Task Scheduler\\{task_name}"))),
        Err(e) => RegisterOutcome::Failed(format!("Register-ScheduledTask {task_name} failed: {e}")),
    }
}

/// Stop + unregister a logon task. Quiet no-op when absent. Returns true
/// when the task existed.
#[cfg(target_os = "windows")]
pub fn unregister_task(task_name: &str) -> Result<bool, String> {
    let cmd = format!(
        "if (Get-ScheduledTask -TaskName {name} -ErrorAction SilentlyContinue) {{ \
           Stop-ScheduledTask -TaskName {name} -ErrorAction SilentlyContinue; \
           Unregister-ScheduledTask -TaskName {name} -Confirm:$false; \
           'EXISTED' \
         }} else {{ 'ABSENT' }}",
        name = ps_quote(task_name),
    );
    powershell(&cmd).map(|out| out.contains("EXISTED"))
}

/// Force-stop any running mootx01 / moot-mgr processes by image name.
///
/// Unregistering a scheduled task only stops instances Task Scheduler is still
/// tracking; a detached or manually-started `moot-mgr serve` (or `mootx01 serve`)
/// survives and keeps its .exe locked, which then fails a later reinstall's
/// binary copy with a sharing violation. Killing by image name unlocks them.
///
/// EXCLUDES the current process: the `mootx01 uninstall` CLI is itself a
/// `mootx01.exe`, so an unguarded kill-by-name would terminate this very process
/// mid-uninstall. The `$_.Id -ne <self-pid>` guard skips it.
#[cfg(target_os = "windows")]
pub fn stop_processes() {
    let self_pid = std::process::id();
    let cmd = format!(
        "Get-Process -Name mootx01,moot-mgr -ErrorAction SilentlyContinue | \
         Where-Object {{ $_.Id -ne {self_pid} }} | \
         Stop-Process -Force -ErrorAction SilentlyContinue",
    );
    let _ = powershell(&cmd);
}

/// Stop + start a registered task (upgrade restart path).
#[cfg(target_os = "windows")]
pub fn restart_task(task_name: &str) -> Result<(), String> {
    let cmd = format!(
        "if (-not (Get-ScheduledTask -TaskName {name} -ErrorAction SilentlyContinue)) {{ \
           throw 'task not registered' \
         }}; \
         Stop-ScheduledTask -TaskName {name} -ErrorAction SilentlyContinue; \
         Start-ScheduledTask -TaskName {name}",
        name = ps_quote(task_name),
    );
    powershell(&cmd).map(|_| ())
}

/// The daemon unit: runs `mootx01 serve --http auto` (§3 hunting form).
/// `data_dir_override` bakes an MOOTX01_DATA_DIR Environment= line when set.
/// `vault_on` bakes MOOTX01_VAULT=1 (vault surface enabled, the default) or
/// MOOTX01_VAULT=0 (vault surface hidden, installed with --vault-off) per ADR-015.
/// MOOTX01_VAULT is always written so the resident daemon's posture is explicit
/// and independent of whatever the launching shell's environment happens to carry.
///
/// Returns `Err` when `data_dir_override` contains CR or LF, which would allow
/// injection of additional systemd directives (planned hardening — fails CLOSED).
pub fn daemon_unit(
    binary_path: &str,
    data_dir_override: Option<&str>,
    vault_on: bool,
) -> Result<String, String> {
    if let Some(d) = data_dir_override {
        if !is_systemd_safe(d) {
            return Err(format!(
                "MOOTX01_DATA_DIR value contains newline characters unsafe for systemd Environment= interpolation: {d:?}"
            ));
        }
    }
    let env_data = data_dir_override
        .map(|d| format!("Environment=MOOTX01_DATA_DIR={d}\n"))
        .unwrap_or_default();
    let vault_val = if vault_on { "1" } else { "0" };
    Ok(format!(
        "[Unit]\n\
         Description=mootx01 resident daemon (ARIA MCP server + autonomic governor)\n\
         After=default.target\n\
         \n\
         [Service]\n\
         ExecStart={binary_path} serve --http auto\n\
         Restart=on-failure\n\
         RestartSec=2\n\
         Environment=MOOTX01_VAULT={vault_val}\n\
         {env_data}\
         \n\
         [Install]\n\
         WantedBy=default.target\n"
    ))
}

/// The mgr unit: runs `moot-mgr serve`. The control channel requires a
/// bearer token (>=16 chars); registration generates one and bakes it into
/// the unit, which is written 0600.
///
/// Returns `Err` when `data_dir_override` contains CR or LF, which would allow
/// injection of additional systemd directives (planned hardening — fails CLOSED).
pub fn mgr_unit(
    mgr_binary_path: &str,
    control_token: &str,
    data_dir_override: Option<&str>,
) -> Result<String, String> {
    if let Some(d) = data_dir_override {
        if !is_systemd_safe(d) {
            return Err(format!(
                "MOOTX01_DATA_DIR value contains newline characters unsafe for systemd Environment= interpolation: {d:?}"
            ));
        }
    }
    let env_data = data_dir_override
        .map(|d| format!("Environment=MOOTX01_DATA_DIR={d}\n"))
        .unwrap_or_default();
    Ok(format!(
        "[Unit]\n\
         Description=moot-mgr resident host (dashboard + control channel)\n\
         After=mootx01.service\n\
         \n\
         [Service]\n\
         ExecStart={mgr_binary_path} serve\n\
         Restart=on-failure\n\
         RestartSec=2\n\
         Environment=MOOT_MGR_CONTROL_TOKEN={control_token}\n\
         {env_data}\
         \n\
         [Install]\n\
         WantedBy=default.target\n"
    ))
}

/// `~/.config/systemd/user/`
pub fn systemd_user_dir(home: &Path) -> PathBuf {
    home.join(".config/systemd/user")
}

/// Whether a per-user systemd is reachable.
pub fn systemd_available() -> bool {
    if !cfg!(target_os = "linux") {
        return false;
    }
    Command::new("systemctl")
        .args(["--user", "is-system-running"])
        .output()
        .map(|o| {
            // Any answer (even "degraded") means the user manager exists;
            // total failure to talk to it means no systemd.
            o.status.success() || !o.stdout.is_empty()
        })
        .unwrap_or(false)
}

#[derive(Debug)]
pub enum RegisterOutcome {
    /// Unit written and started; carries the unit path.
    Registered(PathBuf),
    /// No systemd on this host: unit content returned for manual setup.
    ManualInstructions(String),
    /// The binary the unit points at is missing (e.g. moot-mgr not shipped).
    SkippedNoBinary(String),
    /// systemctl failed; carries the diagnostic.
    Failed(String),
}

/// Write + enable + start a unit. Pure-write on non-systemd hosts is
/// replaced by manual instructions per §6.
pub fn register(home: &Path, unit_name: &str, unit_content: &str) -> RegisterOutcome {
    if !systemd_available() {
        return RegisterOutcome::ManualInstructions(format!(
            "No per-user systemd detected. To run the service manually, save this as \
             ~/.config/systemd/user/{unit_name} (or adapt to your init system):\n\n{unit_content}"
        ));
    }
    let dir = systemd_user_dir(home);
    if let Err(e) = std::fs::create_dir_all(&dir) {
        return RegisterOutcome::Failed(format!("cannot create {}: {e}", dir.display()));
    }
    let unit_path = dir.join(unit_name);
    if let Err(e) = std::fs::write(&unit_path, unit_content) {
        return RegisterOutcome::Failed(format!("cannot write {}: {e}", unit_path.display()));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        // Units may carry the mgr control token: keep them user-only.
        let _ = std::fs::set_permissions(&unit_path, std::fs::Permissions::from_mode(0o600));
    }

    for args in [
        vec!["--user", "daemon-reload"],
        vec!["--user", "enable", "--now", unit_name],
    ] {
        match Command::new("systemctl").args(&args).output() {
            Ok(o) if o.status.success() => {}
            Ok(o) => {
                return RegisterOutcome::Failed(format!(
                    "systemctl {} failed: {}",
                    args.join(" "),
                    String::from_utf8_lossy(&o.stderr).trim()
                ))
            }
            Err(e) => return RegisterOutcome::Failed(format!("cannot run systemctl: {e}")),
        }
    }
    // Best-effort: start without an open session.
    let _ = Command::new("loginctl").arg("enable-linger").output();
    RegisterOutcome::Registered(unit_path)
}

/// Stop + disable + remove a unit. Quiet no-op when absent or no systemd.
pub fn unregister(home: &Path, unit_name: &str) -> Result<bool, String> {
    let unit_path = systemd_user_dir(home).join(unit_name);
    let existed = unit_path.exists();
    if systemd_available() {
        let _ = Command::new("systemctl")
            .args(["--user", "disable", "--now", unit_name])
            .output();
    }
    if existed {
        std::fs::remove_file(&unit_path).map_err(|e| e.to_string())?;
        if systemd_available() {
            let _ = Command::new("systemctl").args(["--user", "daemon-reload"]).output();
        }
    }
    Ok(existed)
}

/// Restart a registered unit (upgrade path).
pub fn restart(unit_name: &str) -> Result<(), String> {
    if !systemd_available() {
        return Err("no per-user systemd on this host".into());
    }
    match Command::new("systemctl")
        .args(["--user", "restart", unit_name])
        .output()
    {
        Ok(o) if o.status.success() => Ok(()),
        Ok(o) => Err(String::from_utf8_lossy(&o.stderr).trim().to_string()),
        Err(e) => Err(e.to_string()),
    }
}

/// 32 hex chars for the mgr control token. Unix: /dev/urandom. Windows (no
/// /dev/urandom): 128 bits derived from std's `RandomState`, whose SipHash
/// keys are seeded from OS entropy — unpredictable to other processes,
/// unlike the previous time-derived fallback (a bare timestamp is guessable
/// to within a few million candidates by anyone who can read the task's
/// registration time). Not a substitute for a real CSPRNG in a network
/// context, but the token only gates a loopback UDS/HTTP control channel.
pub fn random_token() -> String {
    let mut bytes = [0u8; 16];
    if std::fs::File::open("/dev/urandom")
        .and_then(|mut f| std::io::Read::read_exact(&mut f, &mut bytes))
        .is_err()
    {
        use std::collections::hash_map::RandomState;
        use std::hash::{BuildHasher, Hasher};
        let h1 = RandomState::new().build_hasher().finish();
        let mut second = RandomState::new().build_hasher();
        second.write_u128(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0),
        );
        let h2 = second.finish();
        bytes[..8].copy_from_slice(&h1.to_le_bytes());
        bytes[8..].copy_from_slice(&h2.to_le_bytes());
    }
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn daemon_unit_shape() {
        let u = daemon_unit("/home/u/.mootx01/bin/mootx01", None, true).unwrap();
        assert!(u.contains("ExecStart=/home/u/.mootx01/bin/mootx01 serve --http auto"));
        assert!(u.contains("Restart=on-failure"));
        assert!(u.contains("WantedBy=default.target"));
        assert!(!u.contains("Environment=MOOTX01_DATA_DIR"));
        // vault-on baked explicitly (ADR-015)
        assert!(u.contains("Environment=MOOTX01_VAULT=1"));
    }

    #[test]
    fn daemon_unit_bakes_data_dir_override() {
        let u = daemon_unit("/b", Some("/srv/moot"), true).unwrap();
        assert!(u.contains("Environment=MOOTX01_DATA_DIR=/srv/moot"));
        assert!(u.contains("Environment=MOOTX01_VAULT=1"));
    }

    #[test]
    fn daemon_unit_vault_off() {
        let u = daemon_unit("/b", None, false).unwrap();
        assert!(u.contains("Environment=MOOTX01_VAULT=0"));
        assert!(!u.contains("MOOTX01_VAULT=1"));
    }

    #[test]
    fn daemon_unit_rejects_newline_in_data_dir() {
        // A CR or LF in MOOTX01_DATA_DIR would allow injecting additional
        // systemd directives after the Environment= line.
        assert!(daemon_unit("/b", Some("/srv/moot\nExecStart=/bin/evil"), true).is_err());
        assert!(daemon_unit("/b", Some("/srv/moot\rExecStart=/bin/evil"), true).is_err());
        // Legitimate paths with spaces or hyphens are safe.
        assert!(daemon_unit("/b", Some("/srv/my-moot data"), true).is_ok());
    }

    #[test]
    fn mgr_unit_carries_token_and_ordering() {
        let u = mgr_unit("/b/moot-mgr", "0123456789abcdef0123456789abcdef", None).unwrap();
        assert!(u.contains("After=mootx01.service"));
        assert!(u.contains("Environment=MOOT_MGR_CONTROL_TOKEN=0123456789abcdef0123456789abcdef"));
        assert!(u.contains("ExecStart=/b/moot-mgr serve"));
    }

    #[test]
    fn mgr_unit_rejects_newline_in_data_dir() {
        assert!(mgr_unit("/b/moot-mgr", "token", Some("/srv\nExecStart=/bin/evil")).is_err());
    }

    #[test]
    fn token_is_32_hex() {
        let t = random_token();
        assert_eq!(t.len(), 32);
        assert!(t.chars().all(|c| c.is_ascii_hexdigit()));
        // Two tokens must differ — catches a degenerate entropy fallback.
        assert_ne!(t, random_token());
    }

    #[test]
    fn daemon_task_command_shapes() {
        // vault-on, no data override: cmd wrapper for MOOTX01_VAULT=1
        let (exe, arg) = daemon_task_command(r"C:\Users\b\AppData\Local\Programs\mootx01\mootx01.exe", None, true).unwrap();
        assert_eq!(exe, "cmd.exe");
        assert!(arg.contains("set MOOTX01_VAULT=1"));
        assert!(arg.contains("serve --http auto"));

        // vault-on with data override
        let (exe, arg) = daemon_task_command(r"C:\p\mootx01.exe", Some(r"D:\moot"), true).unwrap();
        assert_eq!(exe, "cmd.exe");
        assert!(arg.contains(r"set MOOTX01_DATA_DIR=D:\moot&&"));
        assert!(arg.contains("set MOOTX01_VAULT=1"));

        // vault-off
        let (_, arg_off) = daemon_task_command(r"C:\p\mootx01.exe", None, false).unwrap();
        assert!(arg_off.contains("set MOOTX01_VAULT=0"));
        assert!(!arg_off.contains("MOOTX01_VAULT=1"));
    }

    #[test]
    fn daemon_task_command_rejects_cmd_injection() {
        // & and | are cmd.exe command separators; a crafted MOOTX01_DATA_DIR
        // containing these would allow arbitrary command execution.
        assert!(daemon_task_command(r"C:\p\mootx01.exe", Some("D:\\moot&& evil.exe"), true).is_err());
        assert!(daemon_task_command(r"C:\p\mootx01.exe", Some("D:\\moot|evil.exe"), true).is_err());
        assert!(daemon_task_command(r"C:\p\mootx01.exe", Some("D:\\moot\nevil"), true).is_err());
        // Paths with plain backslashes, spaces, and hyphens are safe.
        assert!(daemon_task_command(r"C:\p\mootx01.exe", Some(r"D:\my data\moot"), true).is_ok());
    }

    #[test]
    fn mgr_task_command_does_not_embed_token() {
        let token = "0123456789abcdef0123456789abcdef";
        let (exe, arg) = mgr_task_command(r"C:\p\moot-mgr.exe", token, None).unwrap();
        assert_eq!(exe, r"C:\p\moot-mgr.exe");
        assert_eq!(arg, "serve");
        assert!(!exe.contains(token));
        assert!(!arg.contains(token));
        assert!(!arg.contains("MOOT_MGR_CONTROL_TOKEN"));

        let (with_data_exe, with_data) = mgr_task_command(r"C:\p\moot-mgr.exe", token, Some(r"D:\moot")).unwrap();
        assert_eq!(with_data_exe, "cmd.exe");
        assert!(with_data.starts_with(r#"/c "set MOOTX01_DATA_DIR=D:\moot&& "#));
        assert!(with_data.contains(r#""C:\p\moot-mgr.exe" serve"#));
        assert!(!with_data.contains(token));
        assert!(!with_data.contains("MOOT_MGR_CONTROL_TOKEN"));
    }

    #[test]
    fn mgr_task_command_rejects_cmd_injection() {
        let token = "0123456789abcdef0123456789abcdef";
        assert!(mgr_task_command(r"C:\p\moot-mgr.exe", token, Some("D:\\moot&evil.exe")).is_err());
        assert!(mgr_task_command(r"C:\p\moot-mgr.exe", token, Some("D:\\moot\nevil")).is_err());
    }

    #[test]
    fn is_cmd_safe_rejects_injection_chars() {
        // Verify each dangerous cmd.exe metacharacter is caught individually.
        for ch in ['&', '|', '<', '>', '^', '%', '"', ';', '\n', '\r'] {
            let s = format!("C:\\data{ch}evil");
            assert!(!is_cmd_safe(&s), "expected is_cmd_safe to reject char {ch:?}");
        }
        // Normal Windows paths must pass.
        assert!(is_cmd_safe(r"C:\Users\Alice\AppData\Local\Programs\mootx01"));
        assert!(is_cmd_safe(r"D:\my data\moot dir"));
    }

    #[test]
    fn is_systemd_safe_rejects_newlines() {
        assert!(!is_systemd_safe("/srv/moot\nExecStart=/bin/evil"));
        assert!(!is_systemd_safe("/srv/moot\r\nExecStart=/bin/evil"));
        // Normal Linux paths must pass.
        assert!(is_systemd_safe("/home/alice/.local/share/mootx01"));
        assert!(is_systemd_safe("/srv/my-moot data dir"));
    }
}
