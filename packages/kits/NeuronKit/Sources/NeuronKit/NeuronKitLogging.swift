// NeuronKitLogging.swift
// The OSLog subsystem NeuronKit's own loggers write under.
//
// NeuronKit used to read the subsystem from MootProductIdentity, which made a
// library depend on the identity of one product that embeds it — the folder
// name, the bundle identifiers, the logging string. A host that is not that
// product had no business carrying any of it, and the dependency existed for
// this one string.
//
// The subsystem is a host's to set, once, before anything logs. The default is
// NeuronKit's own, so the library is usable with no configuration at all.

public enum NeuronKitLogging {
    /// The OSLog subsystem for every `Logger` NeuronKit creates.
    ///
    /// Set it once during host startup, before any NeuronKit work begins: the
    /// loggers are file-scope constants, so each is bound the first time its
    /// file is touched and a later change does not reach one already bound.
    /// A host that sets nothing gets `com.neuronkit`, which groups NeuronKit's
    /// output on its own rather than borrowing a product's subsystem.
    public nonisolated(unsafe) static var subsystem = "com.neuronkit"
}
