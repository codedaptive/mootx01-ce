# Security Boundaries Are Product Design

A password is entered on a laptop, and a phone asks whether the login should continue. The extra approval feels like a small interruption because the two actions belong to one task. Security depends on the fact that they do not belong to one channel.

If the laptop could press the approval button on the phone, the second factor would add ceremony without adding a boundary; agent-operated software can make the same mistake when the model both requests sensitive access and holds the tool that grants it. A smooth workflow then hides a concentration of authority.

The useful question is broader than whether an action is allowed. Product teams must ask who can reach the action. A second question follows: who can change what is allowed? A boundary becomes real only when the actor requesting authority cannot manufacture the approval.

Agents routinely read material they did not create: email, web pages, customer files, source code, and documents. Some of that material may contain malicious instructions, while ordinary content can still be misunderstood. A prompt that tells the model to behave cannot carry the full weight of a security design.

Convenient interfaces create the temptation; a programmer may add an `unlock` command beside the commands for reading and writing data, expecting the model to call it only after a person asks. The implementation follows the happy conversation and overlooks the hostile one.

Security improves when the product changes the available actions. The agent may request access. It may also explain the need. Approval, however, travels through another channel controlled by a person. A short-lived grant can return to the running task without giving the model a way to create its own grant.

Four questions make that decision reusable:

- Which actor is asking to perform the action?
- What data or capability would the action expose?
- Which channel proves that a person approved it?
- What event or deadline removes the added authority?

The questions keep policy attached to product behavior. A team can review a tool list, user interface, service boundary, or vendor workflow with the same method. Missing answers reveal where a warning message is standing in for a wall.

Expiration deserves equal attention because yesterday's approval can become today's hidden privilege. A grant that lives forever asks the user to remember state the product should manage. Fixed windows and restart behavior constrain the lifetime. Immediate revocation and an audit record turn a moment of consent into a limited capability.

Limits also belong in the design; an application can defend its own tool surface while remaining unable to stop a hostile process already running as the local user. Naming that boundary does not weaken the product because it keeps customers from relying on protection that was never built.

The same restraint applies to business process. A finance agent should not approve its own payment exception, and a support agent should not widen its own access to a customer's private records. Separation may add one human action, yet the added action is useful only when the agent cannot perform it through another route.

The reusable pattern is separation by construction. Put approval on a channel unavailable to the requesting actor, limit its lifetime, and preserve evidence of use.

MOOTx01 faced this issue when restricted and secret memories needed temporary recall. Ordinary agent calls exclude those tiers. The product provides no MCP tool named `unlock`, so a model operating through the memory tools cannot lift its own limit.

On macOS, a person invokes a separate command and proves presence through the operating system. The resulting approval reaches a local control endpoint rather than the agent's tool list. Private access ends at the next local midnight. Secret access lasts thirty minutes, and restarting the service returns both tiers to the locked state.

Those choices carry different parts of the promise; removing the unlock handle blocks self-approval, operating-system authentication identifies the local user, expiration prevents background privilege from lingering, and an immediate lock command gives control back without delay. Tests check both the missing tool and the grant lifecycle.

The design also records sensitive reads under a live grant without copying the protected content into the audit event. A record can therefore answer who widened access and when the access was used. Evidence matters because a boundary that cannot be inspected is difficult to trust after an incident.

No arrangement makes local data untouchable; a process already running with the user's file permissions sits outside this agent boundary, and content deliberately recalled into an AI conversation may be sent to that model provider. The product can make its own promise precise without pretending to control the entire machine.

AI is useful for auditing these decisions. An agent can enumerate the exposed tools. Grant creation can be traced from request to expiry. Comparing two implementations can reveal mismatched behavior. Human judgment still decides which authority the model must never own and how much interruption the protected action deserves.

Security boundaries are product design because they determine which actions exist, who can perform them, and how the user regains control. The best boundary is not the one with the sternest warning. It is the one whose normal workflow preserves the separation the product claims to provide.

## Sources
1. MOOTx01 maintainers, "Security Policy," `SECURITY.md`, especially "Security by construction" and "What this does not defend against."

2. MOOTx01 maintainers, `apps/mootx01/Sources/mootx01/Commands/UnlockCommand.swift`, out-of-band approval and expiry behavior.

3. MOOTx01 maintainers, `apps/mootx01/Sources/mootx01/UnlockAuthority.swift`, macOS user-presence verification.

4. MOOTx01 maintainers, `packages/kits/AriaMcpKit/Sources/AriaMCP/SensitivityGrantLedger.swift`, in-memory grants, fixed expiry, restart behavior, and immediate lock.

5. MOOTx01 maintainers, `packages/kits/AriaMcpKit/Tests/AriaMCPTests/ToolProjectionTests.swift`, test that no lock or unlock tool appears on the MCP surface.

6. OWASP Foundation, "Excessive Agency," OWASP Top 10 for Large Language Model Applications, 2025, https://genai.owasp.org/llmrisk/llm062025-excessive-agency/.

7. Bob Pankratz, "Security Boundaries Are Product Design," LinkedIn, July 16, 2026, https://www.linkedin.com/pulse/security-boundaries-product-design-bob-pankratz-lw8mc/.

---

[← Previous: AI Doesn't Need a Good Installer, But You Still Do](03-the-installer-is-part-of-the-product.md) | [Series index](../README.md) | [Technical edition](../technical/04-security-boundaries-are-product-design.md) | [Next: Same Memory Commands. Safer Memory Records. →](06-same-memory-commands-safer-memory-records.md)

Originally published on [LinkedIn](https://www.linkedin.com/pulse/security-boundaries-product-design-bob-pankratz-lw8mc/) on 2026-07-16. Revised for this repository on 2026-07-22.

Copyright 2026 Codedaptive LLC. Article text licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
