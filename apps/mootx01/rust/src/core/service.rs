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
//!
//! The service generator functions (`daemon_unit`, `mgr_unit`,
//! `daemon_task_command`, `mgr_task_command`) return unit or command content
//! as plain strings, keeping them testable on any platform. The platform
//! registration wrappers (`register`, `register_task`) shell out to the
//! service manager and are runtime-guarded.

use std::path::{Path, PathBuf};
use std::process::Command;

/// §6 unit names (plain conventional names — no reverse-DNS off Apple).
pub const DAEMON_UNIT: &str = "mootx01.service";
pub const MGR_UNIT: &str = "mootx01-mgr.service";

/// §6 Windows Task Scheduler task names.
pub const DAEMON_TASK: &str = "mootx01";
pub const MGR_TASK: &str = "mootx01-mgr";

// ---------------------------------------------------------------------------
// Windows Task Scheduler backend
// ---------------------------------------------------------------------------

/// The logon-task action for the daemon: (execute, argument). Always uses a
/// `cmd /c "set …&& …"` wrapper to bake `MOOTX01_VAULT` into the task since
/// Task Scheduler has no per-task environment block. `vault_on` governs
/// `MOOTX01_VAULT`: true → "1" (vault surface enabled), false → "0" (vault
/// surface hidden). The daemon finds its estate through the catalog in the
/// platform configuration directory; nothing about the estate travels in the
/// task.
pub fn daemon_task_command(binary_path: &str, vault_on: bool) -> (String, String) {
    let vault_val = if vault_on { "1" } else { "0" };
    // We always bake MOOTX01_VAULT so the daemon starts with the right
    // vault posture regardless of the parent shell's environment.
    (
        "cmd.exe".to_string(),
        format!("/c \"set MOOTX01_VAULT={vault_val}&& \"{binary_path}\" serve --http auto\""),
    )
}

/// The logon-task action for the mgr: (execute, argument). The bearer token is
/// intentionally not embedded in the action; moot-mgr reads it from the
/// user-local token file written during Windows install.
pub fn mgr_task_command(mgr_binary_path: &str, _control_token: &str) -> (String, String) {
    (mgr_binary_path.to_string(), "serve".to_string())
}

/// The moot-mgr control token file: `<configuration>/moot-mgr/control.token`,
/// beside the manager's store, where moot-mgr reads its default token.
#[cfg(target_os = "windows")]
pub fn mgr_control_token_file() -> PathBuf {
    genius_locus_kit::EstateCatalog::configuration_directory()
        .join("moot-mgr")
        .join("control.token")
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

/// Write a per-task VBScript launcher that runs the task's command with a
/// HIDDEN window (`WScript.Shell.Run <cmd>, 0`) and return its path. The task
/// runs this through `wscript.exe`, a windowless host, so the daemon never
/// flashes a console window at logon. This is the documented, non-elevated way
/// to run a scheduled console task with no window: the `-Hidden` task setting
/// only hides the entry in the Task Scheduler UI (per Microsoft docs), and an
/// S4U / "run whether logged on or not" principal is denied to a non-admin
/// per-user install. The daemon binary is untouched — only how the task
/// launches it.
#[cfg(target_os = "windows")]
fn write_hidden_launcher(task_name: &str, execute: &str, argument: &str) -> Result<String, String> {
    // The launcher lives in the product's configuration directory
    // (`%LOCALAPPDATA%\com.mootx01.ce`), the one folder the install owns.
    let dir = genius_locus_kit::EstateCatalog::configuration_directory();
    std::fs::create_dir_all(&dir).map_err(|e| format!("create {}: {e}", dir.display()))?;
    let vbs_path = dir.join(format!("{task_name}.vbs"));
    // The command line the task would otherwise run directly. Quote the
    // executable (paths may contain spaces) and double every `"` so the whole
    // line survives the VBScript string literal. Run(cmd, 0, True): 0 = hidden
    // window; True = wait, so wscript stays bound to the daemon for the task's
    // lifetime (like the old `cmd /c serve`) — the task stays "running" and its
    // RestartCount/RestartInterval auto-restart still applies on daemon exit.
    let cmdline = format!("\"{execute}\" {argument}");
    let vbs = format!(
        "Set objShell = CreateObject(\"wscript.shell\")\r\nobjShell.Run \"{}\", 0, True\r\n",
        cmdline.replace('"', "\"\"")
    );
    std::fs::write(&vbs_path, vbs).map_err(|e| format!("write {}: {e}", vbs_path.display()))?;
    Ok(vbs_path.to_string_lossy().into_owned())
}

/// Create (or replace) a per-user logon task and start it now — the
/// `enable --now` equivalent. Uses the Task Scheduler COM API via
/// PowerShell cmdlets: schtasks.exe denies ONLOGON triggers to non-admins,
/// but the COM API permits user-scoped logon triggers without elevation
/// (verified live; keeps the install elevation-free like launchd agents and
/// systemd --user). The task launches its command through a hidden `wscript`
/// VBScript launcher (write_hidden_launcher) so no console window appears.
#[cfg(target_os = "windows")]
pub fn register_task(task_name: &str, execute: &str, argument: &str) -> RegisterOutcome {
    // No-window launch: run the command through a windowless wscript host. The
    // -Hidden task SETTING only hides the entry in the Task Scheduler UI (per
    // Microsoft docs), and an S4U/background principal is denied to non-admins,
    // so a hidden VBScript launcher is the documented non-elevated path.
    let vbs_path = match write_hidden_launcher(task_name, execute, argument) {
        Ok(p) => p,
        Err(e) => return RegisterOutcome::Failed(format!("hidden launcher for {task_name}: {e}")),
    };
    let wscript_arg = format!("//B //Nologo \"{vbs_path}\"");
    // Settings for a persistent resident daemon (NOT the default set):
    //   ExecutionTimeLimit = 0  — no run-time cap. The Task Scheduler default is
    //       PT72H (3 days), which silently kills a long-lived daemon on a machine
    //       that stays logged in past 3 days. 0 = run indefinitely.
    //   AllowStartIfOnBatteries + DontStopIfGoingOnBatteries — a laptop daemon
    //       must not be refused on battery (default) nor stopped when unplugged.
    //   RestartCount/RestartInterval — auto-restart if the process exits/crashes.
    //   MultipleInstances IgnoreNew — if the daemon is already running, do not
    //       start a second instance (the single-writer rule would reject it).
    let cmd = format!(
        "$t = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME; \
         $a = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument {arg}; \
         $s = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) \
              -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries \
              -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) \
              -MultipleInstances IgnoreNew; \
         Register-ScheduledTask -TaskName {name} -Trigger $t -Action $a -Settings $s -Force | Out-Null; \
         Start-ScheduledTask -TaskName {name}",
        arg = ps_quote(&wscript_arg),
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

/// True when the scheduled task is currently running. Estate encryption
/// migration keys "restart afterwards" on this.
#[cfg(target_os = "windows")]
pub fn is_task_running(task_name: &str) -> bool {
    let cmd = format!(
        "if ((Get-ScheduledTask -TaskName {name} -ErrorAction SilentlyContinue).State -eq 'Running') \
         {{ exit 0 }} else {{ exit 1 }}",
        name = ps_quote(task_name),
    );
    powershell(&cmd).is_ok()
}

/// Stop a registered task WITHOUT unregistering it. Estate encryption
/// migration runs stop → clone → swap → start; `restart_task` (stop+start
/// in one call) cannot express that.
#[cfg(target_os = "windows")]
pub fn stop_task(task_name: &str) -> Result<(), String> {
    let cmd = format!(
        "if (-not (Get-ScheduledTask -TaskName {name} -ErrorAction SilentlyContinue)) {{ \
           throw 'task not registered' \
         }}; \
         Stop-ScheduledTask -TaskName {name}",
        name = ps_quote(task_name),
    );
    powershell(&cmd).map(|_| ())
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
/// `vault_on` bakes MOOTX01_VAULT=1 (vault surface enabled, the default) or
/// MOOTX01_VAULT=0 (vault surface hidden, installed with --vault-off).
/// MOOTX01_VAULT is always written so the resident daemon's posture is explicit
/// and independent of whatever the launching shell's environment happens to carry.
/// The daemon finds its estate through the catalog in the platform
/// configuration directory; nothing about the estate travels in the unit.
pub fn daemon_unit(binary_path: &str, vault_on: bool) -> String {
    let vault_val = if vault_on { "1" } else { "0" };
    format!(
        "[Unit]\n\
         Description=mootx01 resident daemon (ARIA MCP server + autonomic governor)\n\
         After=default.target\n\
         \n\
         [Service]\n\
         ExecStart={binary_path} serve --http auto\n\
         Restart=on-failure\n\
         RestartSec=2\n\
         Environment=MOOTX01_VAULT={vault_val}\n\
         \n\
         [Install]\n\
         WantedBy=default.target\n"
    )
}

/// The mgr unit: runs `moot-mgr serve`. The control channel requires a
/// bearer token (>=16 chars); registration generates one and bakes it into
/// the unit, which is written 0600.
pub fn mgr_unit(mgr_binary_path: &str, control_token: &str) -> String {
    format!(
        "[Unit]\n\
         Description=moot-mgr resident host (dashboard + control channel)\n\
         After=mootx01.service\n\
         \n\
         [Service]\n\
         ExecStart={mgr_binary_path} serve\n\
         Restart=on-failure\n\
         RestartSec=2\n\
         Environment=MOOT_MGR_CONTROL_TOKEN={control_token}\n\
         \n\
         [Install]\n\
         WantedBy=default.target\n"
    )
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

/// True when the unit is currently active. Estate encryption migration
/// (CE-1.0.35-08) keys "restart afterwards" on this, so a machine whose
/// daemon was not running does not get one started behind its back.
pub fn is_active(unit_name: &str) -> bool {
    systemd_available()
        && Command::new("systemctl")
            .args(["--user", "is-active", "--quiet", unit_name])
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false)
}

/// Stop a registered unit WITHOUT disabling or removing it, so a later
/// `restart`/`start` brings it back from the same registration. Exists for
/// the estate encryption migration, which must run stop → clone → swap →
/// start; `restart()` (stop+start in one call) cannot express that, and
/// `unregister` would delete the unit the restart needs.
pub fn stop(unit_name: &str) -> Result<(), String> {
    if !systemd_available() {
        return Err("no per-user systemd on this host".into());
    }
    match Command::new("systemctl")
        .args(["--user", "stop", unit_name])
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
        let u = daemon_unit("/home/u/.mootx01/bin/mootx01", true);
        assert!(u.contains("ExecStart=/home/u/.mootx01/bin/mootx01 serve --http auto"));
        assert!(u.contains("Restart=on-failure"));
        assert!(u.contains("WantedBy=default.target"));
        // Nothing about the estate travels in the unit: the catalog names it.
        assert!(!u.contains("MOOTX01_DATA_DIR"));
        // vault-on baked explicitly
        assert!(u.contains("Environment=MOOTX01_VAULT=1"));
    }

    #[test]
    fn daemon_unit_vault_off() {
        let u = daemon_unit("/b", false);
        assert!(u.contains("Environment=MOOTX01_VAULT=0"));
        assert!(!u.contains("MOOTX01_VAULT=1"));
    }

    #[test]
    fn mgr_unit_carries_token_and_ordering() {
        let u = mgr_unit("/b/moot-mgr", "0123456789abcdef0123456789abcdef");
        assert!(u.contains("After=mootx01.service"));
        assert!(u.contains("Environment=MOOT_MGR_CONTROL_TOKEN=0123456789abcdef0123456789abcdef"));
        assert!(u.contains("ExecStart=/b/moot-mgr serve"));
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
        // vault-on: cmd wrapper for MOOTX01_VAULT=1
        let (exe, arg) = daemon_task_command(r"C:\Users\b\AppData\Local\Programs\mootx01\mootx01.exe", true);
        assert_eq!(exe, "cmd.exe");
        assert!(arg.contains("set MOOTX01_VAULT=1"));
        assert!(arg.contains("serve --http auto"));
        // Nothing about the estate travels in the task: the catalog names it.
        assert!(!arg.contains("MOOTX01_DATA_DIR"));

        // vault-off
        let (_, arg_off) = daemon_task_command(r"C:\p\mootx01.exe", false);
        assert!(arg_off.contains("set MOOTX01_VAULT=0"));
        assert!(!arg_off.contains("MOOTX01_VAULT=1"));
    }

    #[test]
    fn mgr_task_command_does_not_embed_token() {
        let token = "0123456789abcdef0123456789abcdef";
        let (exe, arg) = mgr_task_command(r"C:\p\moot-mgr.exe", token);
        assert_eq!(exe, r"C:\p\moot-mgr.exe");
        assert_eq!(arg, "serve");
        assert!(!exe.contains(token));
        assert!(!arg.contains(token));
        assert!(!arg.contains("MOOT_MGR_CONTROL_TOKEN"));
    }
}
