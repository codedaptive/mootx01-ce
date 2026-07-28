# MOOTx01 Privacy Policy

**Effective: July 27, 2026**

This Privacy Policy explains how Codedaptive, LLC ("Codedaptive," "we," or
"us") handles information in MOOTx01. It covers the MOOTx01 app for iPhone,
iPad, and Mac; MOOTx01 Community Edition; the `mootx01` command-line tool and
local services; and MOOTx01 plugins and skills published by Codedaptive.

## The short version

MOOTx01 is local-first software. Your estate—including memories, facts,
journals, links, indexes, and related content—is stored on your device by
default. Codedaptive does not operate a MOOTx01 content backend and does not
receive your estate content, Calendar data, Contacts data, prompts, or local
usage telemetry.

MOOTx01 sends data off your device only when you choose or enable a feature
that requires it, such as iCloud sync, local-network access, federation,
export, or an external AI client. Those destinations are described below.

We do not sell personal information, use MOOTx01 content for advertising, or
track you across apps or websites owned by other companies.

## Information MOOTx01 processes

### Your estate

MOOTx01 stores content that you or an authorized AI client files into your
estate. Depending on the features you use, this may include:

- memories, facts, links, journal entries, rooms, wings, and knowledge-graph
  relationships;
- prompts, search terms, recall results, and content captured through the app,
  Share Sheet, Shortcuts, App Intents, command-line tool, or an AI client;
- indexes, sync metadata, paired-device records, and other information needed
  to organize, retrieve, secure, and synchronize your estate; and
- operational statistics and diagnostics written to local stores.

The durable estate is encrypted at rest using SQLCipher. Encryption keys and
local-network credentials are stored in the Apple Keychain where supported.

### Calendar and Contacts

Calendar and birthday mining are off by default. If you enable a miner and
grant permission:

- the Calendar miner reads the identifier, title, and start time of events in
  the upcoming seven days and files corresponding facts into your estate; and
- the birthday miner reads a contact's identifier, name, and birthday month
  and day and files corresponding facts into your estate.

MOOTx01 requests these permissions only from an attended action. Background
refresh uses an existing permission and does not display a new consent prompt.
Codedaptive does not receive this data.

### App settings and local diagnostics

MOOTx01 stores preferences, feature settings, authorization state, local
service state, and operational telemetry on your device. This information is
used to run and troubleshoot the software. MOOTx01 does not transmit analytics
or crash reports to Codedaptive.

## Apple system integrations

MOOTx01 can integrate with Apple features that you control:

- **Share Sheet, widgets, and app extensions.** Shared content is staged in an
  Apple App Group container until the main app files it into your estate. The
  widget reads a small, local projection containing only memories you marked
  public/exportable; it does not open the estate.
- **Spotlight, Siri, Shortcuts, and App Intents.** MOOTx01 may donate actions
  and derived results to Apple system services. Spotlight indexing is limited
  to memories you marked public/exportable and classified normal or elevated.
  Your use of Apple system services is also governed by your Apple settings and
  Apple's privacy policy.
- **Apple Intelligence.** Features that use Apple's system language model pass
  the information needed for the requested operation to that system service.
  MOOTx01 does not send that information to Codedaptive.
- **Notifications and background activity.** If iCloud sync is enabled,
  CloudKit may send a silent push notification to tell MOOTx01 that private
  CloudKit data changed. MOOTx01 does not use these notifications for
  advertising.
- **Nearby Interaction.** On supported iPhones, you may use Ultra Wideband
  proximity to pair two MOOTx01 estates. MOOTx01 uses Nearby Interaction and
  Multipeer Connectivity during the foreground pairing ceremony and stops the
  session when pairing ends or the app moves to the background.

## When data leaves your device

### Optional iCloud sync

iCloud sync is off by default. If you turn it on, eligible estate records are
sent to the private CloudKit database associated with your Apple Account in
the `iCloud.com.codedaptive.mootx01` container so your devices can converge.
The default sync ceiling permits records classified normal or elevated;
records classified restricted or secret are not sent through this sync path.

Apple operates iCloud and CloudKit. Their handling of synchronized data is
governed by your Apple Account settings and Apple's terms and privacy policy.
Codedaptive does not operate a separate copy of the CloudKit database.

### Optional local-network server

If you explicitly start the portable local-network server, MOOTx01 advertises
a service on your local network and accepts credentialed connections from MCP
clients. Starting the server or revealing its bearer credential requires
device-owner authentication using Face ID, Touch ID, or the device passcode
where supported.

Remote local-network callers are limited to a read-only tool allowlist. Recall
requests are forced through the public/exportable gate, and remote callers
cannot use that server to write, mutate, or erase your estate. The server is
off unless you start it and, by default, serves only while the device is on
power. On iPhone and iPad it serves only while the app is active.

### Pairing and federation

If you pair estates and explicitly start a federation session, MOOTx01 may
exchange eligible estate records directly with the paired device for the
duration of that session. The current balanced federation posture permits
records classified normal or elevated; restricted and secret records are
blocked. Ending the session closes the transport.

Pairing may use a QR payload or, on supported devices, Nearby Interaction and
Multipeer Connectivity. Pairing data includes the device or estate identity
material and cryptographic ceremony payloads needed to authenticate the peer.

### AI clients and model providers

MOOTx01 exposes tools to AI clients through the Model Context Protocol. When
you authorize an AI client to read estate content, that client may include the
returned content in a request to its model provider. Likewise, content you
give an AI client may be filed into MOOTx01 at your direction.

MOOTx01 does not choose the AI provider for those clients or control what the
client does after receiving content. Review the privacy settings and policies
of each AI client and model provider you use.

### Exports, callbacks, and user-directed sharing

Information leaves MOOTx01 when you export it, invoke a callback URL that
returns it to another app, mark it public/exportable and serve it to an
authorized client, or otherwise direct MOOTx01 to share it. The receiving app,
person, device, or service controls its copy.

## Other network connections

MOOTx01 may make the following connections that do not include estate
content:

- optional update checks query GitHub's public release API for
  `codedaptive/mootx01-ce`;
- installation and upgrade tools may download release assets through GitHub,
  Homebrew, winget, or another distribution service; and
- the Apple app communicates with Apple services when you use App Store,
  StoreKit, iCloud, CloudKit, push notifications, or other enabled Apple
  system features.

Each service handles the request under its own terms and privacy policy.

## Purchases and subscriptions

When a MOOTx01 product is distributed through an app store, the store
processes purchases, subscriptions, refunds, and payment information.
Codedaptive may receive transaction status and sales reports needed to
provide, restore, and account for access. Codedaptive does not receive your
full payment-card number from Apple.

## Information Codedaptive receives

Codedaptive receives information only when you intentionally provide it
outside the local MOOTx01 product, for example when you:

- email support or submit a security report;
- open a GitHub issue, discussion, or pull request;
- join a beta-feedback program or complete a form; or
- otherwise contact Codedaptive.

We use that information to respond, provide support, maintain security, and
improve the product. A public GitHub submission is visible under GitHub's
terms. Do not include private estate content in a support request unless you
intend to share it with us.

Our websites may have separate notices describing any logs, cookies, or
analytics used there. Website activity is not MOOTx01 estate content.

## Retention and deletion

Local information remains until you erase it, delete the estate, or remove
the app and its data. MOOTx01 also provides guarded tools for withdrawing or
permanently erasing individual memories.

Deleting a local copy does not automatically delete a copy that you previously
exported or sent to another app, AI provider, person, paired device, or service.
Manage those copies at their destination. Turning off iCloud sync stops future
sync activity but does not itself promise deletion of records already stored
in your private CloudKit database; you can manage the app's iCloud data through
your Apple Account and device settings.

Information you send directly to Codedaptive is retained only as long as
reasonably necessary for support, security, legal, and business-record
purposes.

## Your choices

You can:

- leave Calendar and Contacts miners disabled or revoke their permissions in
  system settings;
- leave iCloud sync disabled;
- keep memories private rather than marking them public/exportable;
- leave the local-network server off, regenerate its credential, or stop it;
- decline or end federation sessions and remove paired peers;
- choose which AI clients and providers may access MOOTx01; and
- erase local content and manage copies held by services you selected.

## Security

MOOTx01 uses measures including encrypted local storage, Keychain-protected
credentials, sensitivity and exportability gates, authenticated peer pairing,
and restricted remote interfaces. No storage or transmission method is
perfectly secure, so protect your device, Apple Account, local network, bearer
credentials, and AI-client accounts.

## Children's privacy

MOOTx01 is not directed to children. Codedaptive does not knowingly collect
children's estate content through MOOTx01.

## Changes to this policy

We may update this policy as the product changes. The effective date above
identifies the current revision, and Community Edition revisions remain
visible in the repository history.

## Contact

Privacy questions: **privacy@codedaptive.com**

Security reports: see [SECURITY.md](SECURITY.md).
