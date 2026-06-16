MOOTx01 - is also a developer kit

**Start here:** the hands-on quickstart is [`docs/start-here/SDK_QUICKSTART.md`](../docs/start-here/SDK_QUICKSTART.md) — add the substrate to a project and run open→capture→recall (Swift + Rust).

packages are independently consumable SDK modules. GLK is not the universal access gate; it is the composition layer for apps that opt into estate semantics. Direct kit and storage use is valid outside GLK estate mode, but those operations do not receive GLK-level audit, grants, federation, or composed recall guarantees unless explicitly routed through GLK.
