// SPDX-License-Identifier: LGPL-2.1-or-later
// Self-update for the XREAL bundle. A newer GitHub release is downloaded in
// the background and accepted only if it is signed with the same certificate
// as the running app. It replaces the app after the player quits.
import Cocoa
import CryptoKit
import Security

// Mutable state (staged) is only touched on the main queue.
final class XREALUpdater: @unchecked Sendable {
    static let shared = XREALUpdater()
    // XREAL_UPDATE_URL points tests at a local server; signatures are still checked.
    let latestRelease = URL(string: ProcessInfo.processInfo.environment["XREAL_UPDATE_URL"] ??
        "https://api.github.com/repos/davnozdu/mpv-xreal-vr-player/releases/latest")!
    let assetName = "XREAL-VR-Player-arm64.zip"
    let checkInterval: TimeInterval = 6 * 60 * 60
    let lastCheckKey = "XREALLastUpdateCheck"
    // .noindex keeps Spotlight, and with it Launch Services, away from the
    // staged copy so "Open With" never lists it.
    let updateDirectory = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches/XREAL VR Player/Update.noindex")
    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/" +
        "LaunchServices.framework/Support/lsregister"
    var staged = false
    var log: LogHelper { return AppHub.shared.log }

    struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let assets: [Asset]
    }

    enum UpdateError: Error {
        case invalid(String)
    }

    func start() {
        if ProcessInfo.processInfo.environment["XREAL_NO_UPDATE"] != nil ||
            Bundle.main.object(forInfoDictionaryKey: "XREALDevelopmentPreview") as? Bool == true {
            return
        }
        forgetOtherCopies()
        // Leave startup and the first frames of a movie alone.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.check() }
        Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in self?.check() }
    }

    // Finder's "Open With" lists every copy Launch Services has ever seen,
    // with versions once they differ: previous installs, opened DMGs, copies
    // in Downloads. The copy installed in Applications unregisters the
    // others, unless one of them is newer.
    func forgetOtherCopies() {
        let fm = FileManager.default
        let app = Bundle.main.bundleURL.standardizedFileURL
        let folders = ["/Applications", NSHomeDirectory() + "/Applications"]
        guard let id = Bundle.main.bundleIdentifier,
              folders.contains(app.deletingLastPathComponent().path) else { return }
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        DispatchQueue.global(qos: .utility).async {
            let others = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id).filter {
                let url = $0.standardizedFileURL
                guard url.path != app.path else { return false }
                let version = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                return !self.isNewer(version as? String ?? "0", than: current) || !fm.fileExists(atPath: url.path)
            }
            if others.isEmpty { return }
            let lsregister = Process()
            lsregister.executableURL = URL(fileURLWithPath: XREALUpdater.lsregister)
            lsregister.arguments = others.flatMap { ["-u", $0.path] }
            do {
                try lsregister.run()
                lsregister.waitUntilExit()
                DispatchQueue.main.async { self.log.verbose("Unregistered \(others.count) other copies of the app") }
            } catch {
                DispatchQueue.main.async { self.log.warning("Could not unregister other copies: \(error)") }
            }
        }
    }

    func check() {
        let now = Date().timeIntervalSince1970
        if staged || now - UserDefaults.standard.double(forKey: lastCheckKey) < checkInterval { return }
        guard let requirement = ownRequirement(), let app = installedApp() else { return }
        UserDefaults.standard.set(now, forKey: lastCheckKey)
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        Task.detached {
            do {
                if let version = try await self.stage(over: current, requirement: requirement, app: app) {
                    DispatchQueue.main.async {
                        self.staged = true
                        self.log.info("Update \(version) is ready and will be installed after quitting")
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: self.updateDirectory)
                self.log.warning("Update check failed: \(error)")
            }
        }
    }

    // Development and ad-hoc builds are pinned to their own code hash, so no
    // release could ever satisfy their requirement.
    func ownRequirement() -> SecRequirement? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code = code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode = staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
              let requirement = requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess,
              let text = text as String?, text.contains("certificate leaf") || text.contains("certificate root") else {
            log.verbose("Automatic updates disabled: not signed with the release certificate")
            return nil
        }
        return requirement
    }

    func installedApp() -> URL? {
        let app = Bundle.main.bundleURL
        let fm = FileManager.default
        guard !app.path.contains("/AppTranslocation/"), fm.isWritableFile(atPath: app.path),
              fm.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
            log.verbose("Automatic updates disabled: the app location is not writable")
            return nil
        }
        return app
    }

    func isNewer(_ version: String, than current: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    func stage(over current: String, requirement: SecRequirement, app: URL) async throws -> String? {
        var request = URLRequest(url: latestRelease)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let release = try JSONDecoder().decode(Release.self, from: try await URLSession.shared.data(for: request).0)
        let version = release.tag_name.replacingOccurrences(of: "xreal-v", with: "")
        guard isNewer(version, than: current) else { return nil }
        guard let zipAsset = release.assets.first(where: { $0.name == assetName }),
              let sumsAsset = release.assets.first(where: { $0.name == "SHA256SUMS.txt" }) else {
            throw UpdateError.invalid("release \(version) has no installer")
        }
        log.info("Downloading update \(version)")

        let fm = FileManager.default
        try? fm.removeItem(at: updateDirectory)
        try fm.createDirectory(at: updateDirectory, withIntermediateDirectories: true)
        let zip = updateDirectory.appendingPathComponent(assetName)
        try fm.moveItem(at: try await URLSession.shared.download(from: zipAsset.browser_download_url).0, to: zip)
        let sums = String(decoding: try await URLSession.shared.data(from: sumsAsset.browser_download_url).0, as: UTF8.self)
        let digest = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
        guard sums.contains("\(digest)  \(assetName)") else { throw UpdateError.invalid("checksum mismatch") }

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, updateDirectory.path]
        try ditto.run()
        ditto.waitUntilExit()
        let newApp = updateDirectory.appendingPathComponent(app.lastPathComponent)
        guard ditto.terminationStatus == 0, let info = Bundle(url: newApp)?.infoDictionary,
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == version else {
            throw UpdateError.invalid("unexpected archive contents")
        }

        // The checksum only guards the download; the signature proves origin.
        var staticCode: SecStaticCode?
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCreateWithPath(newApp as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode = staticCode,
              SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess else {
            throw UpdateError.invalid("signature does not match the installed app")
        }

        // Swap the bundles once this process exits; roll back if the move fails.
        // The old copy goes into the .noindex directory rather than next to
        // the app, then the single installed copy is registered again.
        let script = """
            while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 1; done
            old="$4/previous.app"
            /bin/mv "$3" "$old" || exit 1
            if /bin/mv "$2" "$3"; then
                "$5" -u "$2"; "$5" -u "$old"; "$5" -f "$3"
                /bin/rm -rf "$4"
            else
                /bin/mv "$old" "$3"
            fi
            """
        let installer = Process()
        installer.executableURL = URL(fileURLWithPath: "/bin/sh")
        installer.arguments = ["-c", script, "xreal-update", String(getpid()), newApp.path, app.path,
                               updateDirectory.path, XREALUpdater.lsregister]
        try installer.run()
        return version
    }
}
