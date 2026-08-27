# MOOTx01 Community for macOS

MOOTx01 Community is the open desktop application for a single-owner local
estate. It provides Capture, Recall, Review, graph and engine visibility,
Product Dock attachment, and an explicitly enabled portable MCP listener.

The Community application is physically composed from two open library modules
and its executable target:

```text
MootCommunityGateway → MootCommunityUI → CommunityApp
```

It contains no iPhone or iPad app, App Intents or Shortcuts catalog, CloudKit
sync, personal federation, Calendar or Contacts miners, Foundation Models
integration, widget, or share extension. Those capabilities belong to other
product editions and are absent from this source and dependency graph.

## Verify and test

From the repository root:

```sh
apps/Mootx01-App/scripts/verify-community-boundary.sh
```

The verifier scans Swift imports and conditional imports, checks the exact
Community dependency graph, builds the Community UI, and runs the complete
Community intent and application test suites. It uses the published lockfiles
with automatic package resolution disabled, so verification cannot alter the
reviewed dependency set.

Generate the macOS project with XcodeGen:

```sh
cd apps/Mootx01-App
xcodegen generate
xcodebuild \
  -project Mootx01-App.xcodeproj \
  -scheme Mootx01-Community-macOS \
  -destination 'platform=macOS' \
  build
```

`community-export.json` records the reviewed publication boundary that
produced this tree. Paths in its `forbidden` list must remain absent.

## Release artifact

Run the release command from the projected public CE checkout. A full release
requires a notarytool keychain profile and fails before notarization unless the
embedded Developer ID profile authorizes the Community/daemon App Group:

```sh
apps/Mootx01-App/scripts/release-community.sh \
  --output-root /absolute/external/build/path \
  --notary-keychain-profile PROFILE
```

Use `--prepare-only` instead of `--notary-keychain-profile` to produce the
verified notarization input without submitting it.
