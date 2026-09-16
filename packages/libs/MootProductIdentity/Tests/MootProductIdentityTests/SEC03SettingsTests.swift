import Foundation
import Testing
@testable import MootProductIdentity

@Test func lsaSettingsDefaultsAndBounds() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let defaults = MootProductIdentity.Settings.load(configurationDirectory: directory)
    #expect(defaults.corpusLSARetrainingMaxDocuments == 2048)
    #expect(defaults.corpusLSARetrainingMaxSweeps == 30)
    #expect(defaults.corpusLSARetrainingTimeoutMilliseconds == 30000)
    let config = directory.appendingPathComponent("config.json")
    try Data(#"{"corpus":{"lsa_retraining":{"max_documents":-2,"max_sweeps":0,"timeout_milliseconds":125}}}"#.utf8).write(to: config)
    let bounded = MootProductIdentity.Settings.load(configurationDirectory: directory)
    #expect(bounded.corpusLSARetrainingMaxDocuments == 1)
    #expect(bounded.corpusLSARetrainingMaxSweeps == 1)
    #expect(bounded.corpusLSARetrainingTimeoutMilliseconds == 125)
    try Data(#"{"corpus":{"lsa_retraining":{"max_documents":true,"max_sweeps":1.5,"timeout_milliseconds":"100"}}}"#.utf8).write(to: config)
    let invalid = MootProductIdentity.Settings.load(configurationDirectory: directory)
    #expect(invalid.corpusLSARetrainingMaxDocuments == 2048)
    #expect(invalid.corpusLSARetrainingMaxSweeps == 30)
    #expect(invalid.corpusLSARetrainingTimeoutMilliseconds == 30000)
}
