import Foundation
import Testing
@testable import MootProductIdentity

@Test func recallBudgetSettingsCannotDisableSafetyCeiling() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(MootProductIdentity.Settings.load(configurationDirectory: directory).recallDistillationMaxSourceBytes == 32768)
    for (value, expected) in [("1024", 1024), ("0", 1), ("-1", 1), ("999999", 32768), ("true", 32768), ("1.5", 32768), ("\"64\"", 32768)] {
        try Data("{\"recall_distillation\":{\"max_source_bytes\":\(value)}}".utf8)
            .write(to: directory.appendingPathComponent("config.json"))
        #expect(MootProductIdentity.Settings.load(configurationDirectory: directory).recallDistillationMaxSourceBytes == expected)
    }
}
