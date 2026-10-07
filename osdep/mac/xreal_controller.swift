// SPDX-License-Identifier: LGPL-2.1-or-later
// XREAL-specific behavior is activated only in our separately identified bundle.
import Cocoa

class XREALController: NSObject {
    static let shared = XREALController()
    static var isXREAL: Bool { Bundle.main.bundleIdentifier == "com.davnozdu.xreal-vr-player" }
    var lastDisplay: String?

    static func arguments() -> [String] {
        let resources = Bundle.main.resourcePath!
        let preview = Bundle.main.object(forInfoDictionaryKey: "XREALDevelopmentPreview") as? Bool == true
        let state = NSHomeDirectory() + "/Library/Application Support/XREAL VR Player"
        let cache = NSHomeDirectory() + "/Library/Caches/XREAL VR Player"
        try? FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
        let arguments = [CommandLine.arguments[0], "--no-config", "--load-scripts=no",
                "--script=\(resources)/xreal.lua", "--glsl-shaders=\(resources)/xreal.glsl",
                "--input-conf=\(resources)/input.conf", "--script-opts=xreal-prefs=\(state)/preferences.json,xreal-shaders=\(resources),xreal-autofs=yes,xreal-autodecode=yes,osc-idlescreen=no,osc-deadzonesize=0,osc-hidetimeout=1000",
                "--watch-later-directory=\(state)/watch_later", "--gpu-shader-cache-dir=\(cache)/shaders",
                "--icc-cache-dir=\(cache)/icc",
                "--log-file=\(NSHomeDirectory())/Library/Logs/XREAL-VR-Player\(preview ? "-Preview" : "").log",
                "--idle=yes", "--force-window=immediate", "--keep-open=yes",
                "--vo=gpu-next,gpu", "--gpu-api=vulkan", "--gpu-context=macvk",
                "--macos-render-timer=system",
                "--scale=bilinear", "--cscale=bilinear", "--dscale=bilinear",
                "--hwdec=auto-safe", "--hr-seek=yes", "--ao=coreaudio", "--vd-lavc-threads=0",
                "--demuxer-max-bytes=256MiB", "--demuxer-readahead-secs=10",
                "--video-aspect-override=16:9", "--autofit=1100x700", "--native-fs=no",
                "--osd-level=0", "--sub=no", "--title=XREAL VR Player\(preview ? " Test" : "")",
                // Built-in OSD menus and yt-dlp support are unusable split
                // between two eyes; skipping them opens movies sooner.
                "--ytdl=no", "--load-stats-overlay=no", "--load-console=no", "--load-auto-profiles=no",
                "--load-select=no", "--load-positioning=no", "--load-commands=no", "--load-context-menu=no",
                "--window-dragging=yes", "--cursor-autohide=1000"]
        return arguments
    }

    func start() {
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Lua and VO start asynchronously; repeat discovery once they are ready.
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.updateDisplay() }
        updateDisplay()
        XREALUpdater.shared.start()
    }

    @objc func displaysChanged() { updateDisplay() }

    func updateDisplay() {
        let screens = NSScreen.screens
        guard let index = screens.firstIndex(where: {
            let name = $0.localizedName.lowercased()
            return name.contains("xreal") || name.contains("nreal")
        }) else {
            _ = AppHub.shared.input.command("script-message xreal-display preview")
            lastDisplay = "preview"
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
        Без очков показывается один вид на экране Mac. F — полный экран; Esc — окно.
        На очках включите 3D Mode → Full SBS (3840×1080) или Half SBS (1920×1080).
        Плеер автоматически выбирает дисплей XREAL и формат вывода.

        В меню XREAL выбирается формат фильма. Авто определяет формат по имени и размеру кадра: обычное видео без пометок SBS/3D/180/360 показывается как 2D, для немаркированного 8K 2:1 предполагается VR180 SBS. Если картинка неверная, выберите формат вручную — выбор запоминается для файла.
        Обычное 2D-видео на очках 1920×1080 показывается одной картинкой, как в обычном плеере. Стереофильмы с пометкой SBS/3D/180/360 в имени делятся на два глаза автоматически.

        Пробел — пауза; ←/→ — 5 секунд, ↑/↓ — минута; шкала перемотки появляется при движении мыши; W/A/S/D — обзор панорамы;
        [ / ] — угол обзора; R — центр; E — поменять глаза; H — подсказка.

        Eye/3DoF/6DoF закрепляют экран силами очков. Данные позы головы для обзора панорамы эта версия не получает. Субтитры отключены. Шкала перемотки показывается только в обычном виде без 3D, чтобы не пересекать границу глаз.
        """
        alert.runModal()
    }
}
