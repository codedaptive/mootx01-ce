import PackagePlugin
import Foundation

/// SPM BuildToolPlugin that auto-regenerates StaticAssets.swift from the
/// DashboardAssets/ source files before every build.
///
/// Uses `prebuildCommand`, which runs unconditionally before the target is
/// built and whose `outputFilesDirectory` is automatically added as a Swift
/// source root for the target. The script generates StaticAssets.swift into
/// the plugin work directory (sandbox-safe), which SPM compiles in place of
/// the source-tree copy (excluded from the target in Package.swift).
///
/// The idempotency guard inside gen_static_assets.sh exits early when no
/// asset files have changed, keeping incremental builds fast.
///
/// Applied to the `MootManager` target in Package.swift.
@main
struct GenStaticAssetsPlugin: BuildToolPlugin {
    func createBuildCommands(
        context: PluginContext,
        target: Target
    ) async throws -> [Command] {
        let scriptURL = context.package.directoryURL
            .appendingPathComponent("Sources/MootManager/DashboardAssets/gen_static_assets.sh")
        // Generate StaticAssets.swift into the plugin work directory. SPM
        // adds outputFilesDirectory to the target's Swift source root, so
        // the generated file is compiled automatically. The source-tree copy
        // is excluded from MootManager to prevent duplicate-definition errors.
        let outputURL = context.pluginWorkDirectoryURL
            .appendingPathComponent("StaticAssets.swift")

        return [
            .prebuildCommand(
                displayName: "Regenerate StaticAssets.swift from DashboardAssets",
                executable: URL(fileURLWithPath: "/bin/bash"),
                arguments: [scriptURL.path, outputURL.path],
                outputFilesDirectory: context.pluginWorkDirectoryURL
            )
        ]
    }
}
