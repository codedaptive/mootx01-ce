; mootx01-setup.iss — Inno Setup script for MOOTx01 on Windows.
;
; Produces a single mootx01-setup.exe that:
;   1. Places mootx01.exe and moot-mgr.exe into {%USERPROFILE}\.mootx01\bin
;      (the product-wide binary contract shared with install.ps1 and
;      `mootx01 upgrade` — NOT {userappdata}, which is Roaming AppData)
;   2. Adds that directory to the user PATH
;   3. Runs `mootx01 install` as a post-install step so the user can
;      select which AI clients to wire (interactive terminal picker)
;
; Build:
;   iscc.exe /DMyAppVersion=1.0.0 /DArch=x86_64 mootx01-setup.iss
;
; The binaries (mootx01.exe, moot-mgr.exe) must be in the same directory
; as this script, or pass /DBinDir=path\to\binaries.

#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif
#ifndef Arch
  #define Arch "x86_64"
#endif
#ifndef BinDir
  #define BinDir "."
#endif

[Setup]
AppId={{E3A7B1C9-4D2F-4E8A-B5C6-1F9D0A2E3B4C}
AppName=MOOTx01
AppVersion={#MyAppVersion}
AppPublisher=Codedaptive LLC
AppPublisherURL=https://github.com/codedaptive/mootx01-ce
AppSupportURL=https://github.com/codedaptive/mootx01-ce/issues
DefaultDirName={%USERPROFILE}\.mootx01\bin
; Do not reuse a remembered install dir: pre-1.0.6 betas installed to
; {userappdata} (Roaming) by mistake; upgrades must migrate to the
; contract path or `mootx01 upgrade` writes where PATH doesn't point.
UsePreviousAppDir=no
DisableProgramGroupPage=yes
DisableDirPage=yes
; User-scoped install — no admin elevation required.
PrivilegesRequired=lowest
OutputBaseFilename=mootx01-{#MyAppVersion}-windows-{#Arch}-setup
Compression=lzma2/ultra64
SolidCompression=yes
; Modern visual style
WizardStyle=modern
WizardSizePercent=110
SetupIconFile=compiler:SetupClassicIcon.ico
UninstallDisplayIcon={app}\mootx01.exe

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "{#BinDir}\mootx01.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BinDir}\moot-mgr.exe"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist

[InstallDelete]
; Migrate pre-1.0.6 beta installs that landed in Roaming AppData: remove
; the stray binaries so PATH cannot resolve a stale copy. The leftover
; Roaming PATH entry (if any) is harmless once these are gone.
Type: files; Name: "{userappdata}\.mootx01\bin\mootx01.exe"
Type: files; Name: "{userappdata}\.mootx01\bin\moot-mgr.exe"

[Registry]
; Add the install dir to the user PATH (same effect as install.ps1).
Root: HKCU; Subkey: "Environment"; ValueType: expandsz; ValueName: "Path"; \
  ValueData: "{olddata};{app}"; Check: NeedsAddPath(ExpandConstant('{app}'))

[Run]
; After files are placed, launch the interactive client wiring in a
; terminal window. The user sees the same numbered picker that
; `mootx01 install` shows in PowerShell — detection, selection, wiring.
Filename: "{app}\mootx01.exe"; Parameters: "install"; \
  Description: "Run MOOTx01 setup now to connect your AI clients - required (opens a terminal)"; \
  Flags: postinstall nowait skipifsilent runasoriginaluser

[UninstallRun]
; Run `mootx01 uninstall --yes` before deleting files so client configs
; and scheduled tasks are cleaned up (same sequence as install.ps1).
Filename: "{app}\mootx01.exe"; Parameters: "uninstall --yes"; \
  Flags: runhidden waituntilterminated skipifdoesntexist

[UninstallDelete]
; Clean up the install directory. Estate data under %LOCALAPPDATA%\MOOTx01
; is intentionally left intact (the uninstall message notes this).
Type: filesandordirs; Name: "{app}"

[Messages]
WelcomeLabel1=Welcome to MOOTx01 Setup
WelcomeLabel2=MOOTx01 gives your AI tools a persistent, private memory that lives on your machine.%n%nThis will install MOOTx01 and let you connect your AI clients.%n%nClick Next to continue.
FinishedLabel=MOOTx01 has been installed.%n%nIf you checked "Connect AI clients," a terminal window will open to let you select which clients to wire.%n%nYour estate data is stored at %LOCALAPPDATA%\MOOTx01 and stays on this machine.

[Code]
// Check whether the install dir is already on the user PATH.
// Prevents duplicate entries on reinstall.
function NeedsAddPath(Param: string): Boolean;
var
  OrigPath: string;
begin
  if not RegQueryStringValue(HKEY_CURRENT_USER,
    'Environment', 'Path', OrigPath) then
  begin
    Result := True;
    exit;
  end;
  // Look for the path both with and without trailing backslash.
  Result := (Pos(';' + Param + ';', ';' + OrigPath + ';') = 0) and
            (Pos(';' + Param + '\;', ';' + OrigPath + ';') = 0);
end;

// On uninstall, notify the user their data was preserved — but only in
// interactive mode. UninstallSilent (NOT WizardSilent, which per the Inno
// docs reports whether *Setup* ran silently) is the documented function for
// detecting a silent uninstall; gating on it keeps `/VERYSILENT` uninstall
// from hanging on a modal MsgBox — a Winget validation-VM requirement.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
    if not UninstallSilent then
      MsgBox('MOOTx01 has been removed.' + #13#10 + #13#10 +
             'Your estate data at %LOCALAPPDATA%\MOOTx01 was not deleted. ' +
             'Remove that folder manually if you want to erase your data.',
             mbInformation, MB_OK);
end;
