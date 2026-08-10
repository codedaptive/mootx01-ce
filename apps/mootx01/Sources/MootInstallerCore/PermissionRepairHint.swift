import Foundation

extension Installer {
    /// Turns a permission failure on the PATH directory into an actionable message.
    ///
    /// The .pkg postinstall runs as root and `mkdir -p ~/.local/bin` left both that
    /// directory and `~/.local` root-owned until 2026-08-05; only the symlinks inside
    /// were chowned back. Replacing a symlink needs write permission on the
    /// CONTAINING directory, so `mootx01 install` failed with EPERM surfaced as
    /// NSCocoaErrorDomain 513 — "couldn't be removed because you don't have
    /// permission". The raw NSError told the user nothing; diagnosing a real report
    /// on 2026-08-05 took a person reading directory ownership by hand.
    ///
    /// The postinstall no longer creates the problem, but installs made by an earlier
    /// package are already broken on disk, so the message has to carry the repair.
    /// Returns nil when the failure is not this one — never guess at an unrelated error.
    public static func permissionRepairHint(for error: Error, homeDirectory: URL) -> String? {
        let ns = error as NSError
        let isPermission = (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteNoPermissionError)
            || (ns.domain == NSCocoaErrorDomain && ns.code == 513)
            || ((ns.underlyingErrors.first as NSError?)?.code == 13)
        guard isPermission else { return nil }

        let localBin = MootPaths.localBinDirURL(homeDirectory: homeDirectory).path
        let dotLocal = homeDirectory.appendingPathComponent(".local").path
        let user = NSUserName()
        return """

        This is a known packaging defect in installers before 1.1.0-beta-13: the .pkg
        created \(dotLocal) and \(localBin) as root, so your account cannot replace
        the symlinks inside them. Nothing is wrong with your machine or your download.

        Repair those two directories, then re-run install:

          sudo chown \(user):staff "\(dotLocal)" "\(localBin)"
          \(MootPaths.installedBinaryURL(homeDirectory: homeDirectory).path) install

        Only those two directories are re-owned — nothing else in \(dotLocal) is touched.
        """
    }
}
