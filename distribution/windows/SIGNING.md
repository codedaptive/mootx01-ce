# Windows code signing — Azure Artifact Signing

The Windows binaries (`mootx01.exe`, `moot-mgr.exe`) and the Inno `setup.exe`
are Authenticode-signed with **Azure Artifact Signing** (formerly Azure Trusted
Signing). Signing attaches a verified publisher identity, which:

- clears the **Microsoft Defender** scan that blocks winget PR validation
  (the `validationDefender` error), and
- removes the **SmartScreen** warning on direct `setup.exe` download.

This is a two-part setup. The **Azure provisioning** below is a one-time manual
step (only a subscription owner can do it, and identity validation takes time).
The **CI wiring** is already in place in `release.yml` and `candidate.yml`; it
is best-effort and no-ops until the GitHub secrets below exist, so the pipeline
keeps shipping (unsigned) until provisioning completes.

macOS uses Apple Developer ID (see `distribution/macos/`); this doc is Windows
only.

---

## 1. Azure provisioning (one-time, manual)

1. **Paid Azure subscription.** Artifact Signing does not work on free, trial,
   or sponsored subscriptions.
2. **Register the resource provider:** `Microsoft.CodeSigning` on the
   subscription.
3. **Create an Artifact Signing account** in a supported region. The region
   fixes the signing **endpoint** URL, e.g. East US → `https://eus.codesigning.azure.net/`.
4. **Identity Validation** — create an identity validation request for
   Codedaptive (Organization) and complete Microsoft's verification. **This is
   the long pole** (hours to days). Signing cannot be configured until it
   succeeds.
5. **Certificate Profile** — create a profile of type **Public Trust** bound to
   the validated identity. Its **name** is `AZURE_CODESIGN_PROFILE`; the
   account name is `AZURE_CODESIGN_ACCOUNT`.
6. **App Registration** (Entra ID) for CI to authenticate as.
7. **Grant the App Registration the `Trusted Signing Certificate Profile
   Signer` role** on the signing account (RBAC). This is the only permission it
   needs — least privilege.
8. **Wire CI authentication** — choose one of the two options in §2.

---

## 2. CI authentication — choose one

The workflows are currently wired for **Option A (OIDC)**. Switching to Option B
is a small wiring change (drop `azure/login`, pass `azure-client-secret` to the
signing action) — say so if you prefer it.

### Option A — OIDC federated credentials (recommended; no stored secret)

Most secure: no long-lived secret in GitHub. On the App Registration, add
**federated credentials** whose subject matches each workflow's trigger:

- **candidate.yml** runs on branch `candidate/1.0.x`:
  subject `repo:codedaptive/mootx01-ce:ref:refs/heads/candidate/1.0.x`
- **release.yml** runs on **tag** pushes. GitHub's OIDC subject for a tag is
  `repo:codedaptive/mootx01-ce:ref:refs/tags/<tag>`, and Azure federated
  credentials **cannot wildcard** the tag. The clean fix is a GitHub Actions
  **Environment** (e.g. `release`) on the two Windows release jobs, then a
  federated credential with subject
  `repo:codedaptive/mootx01-ce:environment:release`.
  > NOTE: the release Windows jobs do **not** yet declare `environment: release`.
  > Adding it is the remaining wiring step for the OIDC-on-tags path — ping me to
  > add it once the environment exists, or use Option B, which needs no
  > environment.

### Option B — client secret (simplest; works on branch and tag triggers)

Create a client secret on the App Registration and store it as
`AZURE_CLIENT_SECRET`. Works identically for branch- and tag-triggered runs with
no federated-subject matching. Trade-off: a long-lived secret in GitHub (scoped
only to the signer role; rotate periodically).

---

## 3. GitHub Actions secrets to add

Repository → Settings → Secrets and variables → Actions:

| Secret | Value |
|---|---|
| `AZURE_CODESIGN_ENDPOINT` | Region endpoint, e.g. `https://eus.codesigning.azure.net/` |
| `AZURE_CODESIGN_ACCOUNT` | Artifact Signing account name |
| `AZURE_CODESIGN_PROFILE` | Certificate Profile name |
| `AZURE_CLIENT_ID` | App Registration (client) ID |
| `AZURE_TENANT_ID` | Entra tenant (directory) ID |
| `AZURE_SUBSCRIPTION_ID` | Subscription ID |
| `AZURE_CLIENT_SECRET` | **Option B only** — App Registration client secret |

`AZURE_CLIENT_ID` is the gate: the workflows check for it and skip signing (with
a warning) when it is absent, so adding these secrets is what activates signing.

---

## 4. How the workflows use it

Both workflows sign in the same place:

1. Build `mootx01.exe` + `moot-mgr.exe`, copy to the workspace root.
2. **Sign the two exes** (before zip and before Inno, so the archive and the
   installer both embed signed exes).
3. Zip; build the Inno `setup.exe`.
4. **Sign `setup.exe`.**

- **candidate.yml** (`windows` matrix job): best-effort — signs when creds are
  present, ships unsigned with a warning when not. This is where to validate
  signing on a real build (including the arm64 leg — the signing tool runs under
  x64 emulation on `windows-11-arm`, same as Inno Setup 6).
- **release.yml** (`build-windows-x86_64`, `build-windows-arm64`): signs on a
  real tag push when creds are present.

The signing action is pinned by commit SHA:
`azure/artifact-signing-action@c7ab2a8` (v2.0.0), auth via
`azure/login@532459e` (v3.0.0).

---

## 5. Activation and verification

1. Complete §1–§3.
2. Cut a **candidate** build and confirm the `windows` job runs the signing
   steps (not the skip warning) on both arches.
3. Download `setup.exe` from the candidate and verify:
   `signtool verify /pa /v mootx01-<ver>-windows-x86_64-setup.exe`
   (or right-click → Properties → Digital Signatures → publisher = Codedaptive).
4. Re-run the blocked winget PR check; the Defender error should clear.
5. **Tighten `release.yml` to fail closed.** Once a signed release is verified,
   change each `Azure signing preflight` step so a missing `AZURE_CLIENT_ID`
   is a hard error instead of a warning — a published stable release must not
   silently ship unsigned. (macOS already fails closed via `REQUIRE_SIGNING`.)

---

## 6. Cost

~$9.99/month (Artifact Signing Basic: 5,000 signatures / 1 certificate profile).
Requires a paid Azure subscription.
