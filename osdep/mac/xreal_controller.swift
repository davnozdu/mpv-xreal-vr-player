// SPDX-License-Identifier: LGPL-2.1-or-later
// XREAL-specific behavior is activated only in our separately identified bundle.
import Cocoa

class XREALController: NSObject {
    static let shared = XREALController()
    static var isXREAL: Bool { Bundle.main.bundleIdentifier == "com.davnozdu.xreal-vr-player" }
    var lastDisplay: String?

    static func arguments() -> [String] {
        let resources = Bundle.main.resourcePath!
        let state = NSHomeDirectory() + "/Library/Application Support/XREAL VR Player"
        let cache = NSHomeDirectory() + "/Library/Caches/XREAL VR Player"
        try? FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
        return [CommandLine.arguments[0], "--no-config", "--load-scripts=no",
                "--script=\(resources)/xreal.lua", "--glsl-shaders=\(resources)/xreal.glsl",
                "--input-conf=\(resources)/input.conf", "--script-opts=xreal-prefs=\(state)/preferences.json",
                "--watch-later-directory=\(state)/watch_later", "--gpu-shader-cache-dir=\(cache)/shaders",
                "--icc-cache-dir=\(cache)/icc",
                "--log-file=\(NSHomeDirectory())/Library/Logs/XREAL-VR-Player.log",
                "--idle=yes", "--force-window=immediate", "--keep-open=yes",
                "--vo=gpu-next,gpu", "--gpu-api=vulkan,gl", "--gpu-context=macvk,cocoa",
                "--hwdec=auto-safe", "--ao=coreaudio", "--vd-lavc-threads=0",
                "--demuxer-max-bytes=256MiB", "--demuxer-readahead-secs=10",
                "--video-aspect-override=32:9", "--autofit=1100x500", "--native-fs=no",
                "--osc=no", "--osd-level=0", "--sub=no", "--title=XREAL VR Player",
                "--window-dragging=yes", "--cursor-autohide=1000"]
    }

    func start() {
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Lua and VO start asynchronously; repeat discovery once they are ready.
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.updateDisplay() }
        updateDisplay()
    }

    @objc func displaysChanged() { lastDisplay = nil; updateDisplay() }

    func updateDisplay() {
        let screens = NSScreen.screens
        guard let index = screens.firstIndex(where: {
            let name = $0.localizedName.lowercased()
            return name.contains("xreal") || name.contains("nreal")
        }) else {
            _ = AppHub.shared.input.command("script-message xreal-display preview")
            if lastDisplay != "preview" {
                _ = AppHub.shared.input.command("set fullscreen no")
                lastDisplay = "preview"
            }
            return
        }
        let screen = screens[index]
        let mode = CGDisplayCopyDisplayMode(screen.displayID)
        let width = mode?.pixelWidth ?? Int(screen.frame.width)
        let height = mode?.pixelHeight ?? Int(screen.frame.height)
        let full = Double(width) / Double(max(height, 1)) > 3.0
        // Input becomes ready before Lua scripts are loaded. Re-send discovery
        // so startup cannot lose the display message; Lua ignores duplicates.
        _ = AppHub.shared.input.command("script-message xreal-display \(full ? "full" : "half")")
        let key = "\(screen.displayID):\(width)x\(height):\(index)"
        if lastDisplay == key { return }
        _ = AppHub.shared.input.command("set screen \(index)")
        _ = AppHub.shared.input.command("set fs-screen \(index)")
        _ = AppHub.shared.input.command("set fullscreen yes")
        lastDisplay = key
    }

    @objc func showHelp() {
        let alert = NSAlert()
        alert.messageText = "XREAL VR Player"
        alert.informativeText = """
        Откройте фильм: ⌘O или перетащите файл в окно.
        На очках включите 3D Mode → Full SBS (3840×1080) или Half SBS (1920×1080).
        Плеер автоматически выбирает дисплей XREAL и формат вывода.

        В меню XREAL выбирается формат фильма. Авто определяет формат по имени и размеру кадра; для немаркированного 8K 2:1 предполагается VR180 SBS. Если ракурс неверный, выберите формат вручную.

        Пробел — пауза; ←/→ — перемотка; W/A/S/D — обзор панорамы;
        [ / ] — угол обзора; R — центр; E — поменять глаза; H — подсказка.

        Eye/3DoF/6DoF закрепляют экран силами очков. Данные позы головы для обзора панорамы эта версия не получает. Субтитры и обычный OSC отключены, чтобы не пересекать границу глаз.
        """
        alert.runModal()
    }
}
