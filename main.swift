import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Efectos (sonido + háptico)
enum FX {
    static var soundOn: Bool { UserDefaults.standard.object(forKey: "sound") as? Bool ?? true }
    static var hapticOn: Bool { UserDefaults.standard.object(forKey: "haptic") as? Bool ?? true }
    
    static var hoverSound: String { UserDefaults.standard.string(forKey: "sound_hover") ?? "Tink" }
    static var successSound: String { UserDefaults.standard.string(forKey: "sound_success") ?? "Glass" }
    static var errorSound: String { UserDefaults.standard.string(forKey: "sound_error") ?? "Basso" }
    
    static func play(_ name: String, _ vol: Float = 0.5) {
        guard soundOn, let s = NSSound(named: name) else { return }
        s.volume = vol; s.stop(); s.play()
    }
    
    static func haptic(_ p: NSHapticFeedbackManager.FeedbackPattern) {
        if hapticOn { NSHapticFeedbackManager.defaultPerformer.perform(p, performanceTime: .now) }
    }
    
    static func open() { play("Pop", 0.4); haptic(.levelChange) }
    static func tick() { play(hoverSound, 0.25); haptic(.alignment) }
    static func done(_ ok: Bool) { play(ok ? successSound : errorSound, 0.5); haptic(.generic) }
}

// MARK: - Utilidades
@discardableResult
func run(_ tool: String, _ args: [String]) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
}

func uniqueURL(_ src: URL, suffix: String = "", ext: String) -> URL {
    let dir = src.deletingLastPathComponent()
    let base = src.deletingPathExtension().lastPathComponent + suffix
    var u = dir.appendingPathComponent(base).appendingPathExtension(ext)
    var i = 2
    while FileManager.default.fileExists(atPath: u.path) {
        u = dir.appendingPathComponent("\(base) \(i)").appendingPathExtension(ext); i += 1
    }
    return u
}

func background(_ work: @escaping () -> Bool) {
    DispatchQueue.global(qos: .userInitiated).async {
        let ok = work()
        DispatchQueue.main.async { FX.done(ok) }
    }
}

func utType(_ u: URL) -> UTType? { UTType(filenameExtension: u.pathExtension) }
func isImage(_ u: URL) -> Bool { utType(u)?.conforms(to: .image) ?? false }

func stripMetadata(_ u: URL, gpsOnly: Bool = false) -> Bool {
    guard let s = CGImageSourceCreateWithURL(u as CFURL, nil), let type = CGImageSourceGetType(s) else { return false }
    let out = uniqueURL(u, suffix: gpsOnly ? " sin GPS" : " limpio", ext: u.pathExtension)
    guard let d = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) else { return false }
    let props = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any]
    var opts: [CFString: Any] = gpsOnly
        ? [kCGImagePropertyGPSDictionary: kCFNull as Any]
        : [
            kCGImagePropertyExifDictionary: kCFNull as Any,
            kCGImagePropertyGPSDictionary: kCFNull as Any,
            kCGImagePropertyTIFFDictionary: kCFNull as Any,
            kCGImagePropertyIPTCDictionary: kCFNull as Any,
        ]
    if let o = props?[kCGImagePropertyOrientation] { opts[kCGImagePropertyOrientation] = o }
    CGImageDestinationAddImageFromSource(d, s, 0, opts as CFDictionary)
    return CGImageDestinationFinalize(d)
}

// MARK: - Acciones
enum Mode { case convert, tools, share }

struct Action {
    let title: String
    let symbol: String
    let run: ([URL]) -> Void
}

func convertActions(_ urls: [URL]) -> [Action] {
    let t = utType(urls[0]) ?? .data

    func img(_ title: String, _ fmt: String, _ ext: String) -> Action {
        Action(title: title, symbol: "photo") { us in
            background {
                var ok = true
                for u in us { ok = run("/usr/bin/sips", ["-s", "format", fmt, u.path, "--out", uniqueURL(u, ext: ext).path]) && ok }
                return ok
            }
        }
    }
    func aud(_ title: String, _ fileFmt: String, _ dataFmt: String, _ ext: String) -> Action {
        Action(title: title, symbol: "waveform") { us in
            background {
                var ok = true
                for u in us { ok = run("/usr/bin/afconvert", ["-f", fileFmt, "-d", dataFmt, u.path, uniqueURL(u, ext: ext).path]) && ok }
                return ok
            }
        }
    }
    func vid(_ title: String, _ preset: String, _ ext: String) -> Action {
        Action(title: title, symbol: "film") { us in
            background {
                var ok = true
                for u in us { ok = run("/usr/bin/avconvert", ["--preset", preset, "--source", u.path, "--output", uniqueURL(u, ext: ext).path]) && ok }
                return ok
            }
        }
    }
    func doc(_ title: String, _ fmt: String) -> Action {
        Action(title: title, symbol: "doc.text") { us in
            background {
                var ok = true
                for u in us { ok = run("/usr/bin/textutil", ["-convert", fmt, u.path, "-output", uniqueURL(u, ext: fmt).path]) && ok }
                return ok
            }
        }
    }

    if t.conforms(to: .image) {
        return [img("PNG", "png", "png"), img("JPG", "jpeg", "jpg"), img("HEIC", "heic", "heic"),
                img("TIFF", "tiff", "tiff"), img("GIF", "gif", "gif"), img("PDF", "pdf", "pdf")]
    } else if t.conforms(to: .audio) {
        return [aud("M4A", "m4af", "aac", "m4a"), aud("WAV", "WAVE", "LEI16", "wav"), aud("AIFF", "AIFF", "BEI16", "aiff"),
                aud("CAF", "caff", "LEI16", "caf"), aud("FLAC", "flac", "flac", "flac"), aud("ALAC", "m4af", "alac", "m4a")]
    } else if t.conforms(to: .movie) {
        return [vid("MP4", "Preset1920x1080", "mp4"), vid("MOV", "PresetHEVC1920x1080", "mov"),
                vid("M4V", "PresetAppleM4V1080pHD", "m4v"), vid("720p", "Preset1280x720", "mp4"),
                vid("480p", "Preset640x480", "mp4"), vid("AUDIO", "PresetAppleM4A", "m4a")]
    } else {
        let pdf = Action(title: "PDF", symbol: "doc.richtext") { us in
            var ok = true
            for u in us { ok = docToPDF(u) && ok }
            FX.done(ok)
        }
        return [pdf, doc("DOCX", "docx"), doc("TXT", "txt"),
                doc("RTF", "rtf"), doc("HTML", "html"), doc("ODT", "odt")]
    }
}

func toolActions(_ urls: [URL]) -> [Action] {
    [
        Action(title: "Compress", symbol: "arrow.down.right.and.arrow.up.left") { us in
            background {
                var ok = true
                for u in us {
                    if isImage(u) {
                        ok = run("/usr/bin/sips", ["-s", "format", "jpeg", "-s", "formatOptions", "60", u.path,
                                                   "--out", uniqueURL(u, suffix: " comprimido", ext: "jpg").path]) && ok
                    } else {
                        ok = run("/usr/bin/ditto", ["-c", "-k", "--keepParent", u.path, uniqueURL(u, ext: "zip").path]) && ok
                    }
                }
                return ok
            }
        },
        Action(title: "Metadata", symbol: "tag") { us in
            for (i, u) in us.prefix(5).enumerated() { openMetadata(u, index: i) }
            FX.done(true)
        },
        Action(title: "Edit", symbol: "slider.horizontal.3") { us in openEdit(us) },
        Action(title: "Annotate", symbol: "pencil.tip.crop.circle") { us in openAnnotate(us) },
        Action(title: "Add BG", symbol: "photo") { us in openBackground(us) },
        Action(title: "Crop", symbol: "crop") { us in openCrop(us) },
        Action(title: "Redact", symbol: "eye.slash") { us in openRedact(us) },
    ]
}

func shareActions(_ urls: [URL]) -> [Action] {
    [
        Action(title: "AirDrop", symbol: "airplayaudio") { us in
            NSApp.activate(ignoringOtherApps: true)
            NSSharingService(named: .sendViaAirDrop)?.perform(withItems: us)
        },
        Action(title: "Float", symbol: "pin.fill") { us in
            for (i, u) in us.prefix(5).enumerated() { openFloat(u, index: i) }
            FX.done(true)
        },
        Action(title: "Copy", symbol: "doc.on.doc") { us in
            let pb = NSPasteboard.general; pb.clearContents(); pb.writeObjects(us as [NSURL]); FX.done(true)
        },
        Action(title: "Move", symbol: "folder") { us in
            NSApp.activate(ignoringOtherApps: true)
            let p = NSOpenPanel()
            p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
            p.prompt = "Mover aquí"
            guard p.runModal() == .OK, let dir = p.url else { return }
            background {
                var ok = true
                for u in us {
                    do { try FileManager.default.moveItem(at: u, to: dir.appendingPathComponent(u.lastPathComponent)) }
                    catch { ok = false }
                }
                return ok
            }
        },
        Action(title: "Copy Path", symbol: "doc.plaintext") { us in
            let pb = NSPasteboard.general; pb.clearContents()
            pb.setString(us.map { $0.path }.joined(separator: "\n"), forType: .string); FX.done(true)
        },
        Action(title: "Terminal", symbol: "terminal") { us in
            let dir = us[0].deletingLastPathComponent().path
            background { run("/usr/bin/open", ["-a", "Terminal", dir]) }
        },
    ]
}

// MARK: - Modelo + UI Radial Estilo Cristal Optimizado
final class RadialModel: ObservableObject {
    @Published var actions: [Action] = []
    @Published var hovered: Int? = nil
    @Published var shown = false
    var name = ""
    var thumb: NSImage = NSImage()
}

struct RoundedSector: Shape {
    var a0: Double, a1: Double, r0: CGFloat, r1: CGFloat
    var corner: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        func pt(_ a: Double, _ r: CGFloat) -> CGPoint {
            CGPoint(x: c.x + r * CGFloat(cos(a * .pi / 180)), y: c.y + r * CGFloat(sin(a * .pi / 180)))
        }
        func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        let sweep = CGFloat((a1 - a0) * .pi / 180)
        var v: [CGPoint] = []
        let nOut = max(3, Int(sweep * r1 / 14))
        for i in 0...nOut { v.append(pt(a0 + (a1 - a0) * Double(i) / Double(nOut), r1)) }
        let nIn = max(3, Int(sweep * r0 / 14))
        for i in 0...nIn { v.append(pt(a1 - (a1 - a0) * Double(i) / Double(nIn), r0)) }

        var p = Path()
        let n = v.count
        p.move(to: CGPoint(x: (v[n - 1].x + v[0].x) / 2, y: (v[n - 1].y + v[0].y) / 2))
        for i in 0..<n {
            let prev = v[(i + n - 1) % n], cur = v[i], next = v[(i + 1) % n]
            let rad = min(corner, 0.45 * min(dist(prev, cur), dist(cur, next)))
            p.addArc(tangent1End: cur, tangent2End: next, radius: rad)
        }
        p.closeSubpath()
        return p
    }
}

let PANEL: CGFloat = 360

let glassRim = LinearGradient(colors: [Color.white.opacity(0.85), Color.white.opacity(0.12), Color.white.opacity(0.45)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)

struct WedgeView: View {
    let i: Int, n: Int
    let title: String, symbol: String
    let hot: Bool

    var body: some View {
        let step = 360.0 / Double(n)
        let mid = -90 + Double(i) * step
        let shape = RoundedSector(a0: mid - step / 2 + 3, a1: mid + step / 2 - 3, r0: 78, r1: 152)
        ZStack {
            shape.fill(hot ? Color.orange.opacity(0.88) : Color.black.opacity(0.40))
            shape.fill(LinearGradient(colors: [Color.white.opacity(hot ? 0.35 : 0.15), Color.white.opacity(0.02)],
                                      startPoint: .top, endPoint: .bottom))
            shape.stroke(glassRim, lineWidth: 1.1)

            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                Text(title.uppercased())
                    .font(.system(size: 8.5, weight: .bold))
                    .multilineTextAlignment(.center)
            }
            .foregroundColor(hot ? .white : Color(nsColor: .labelColor))
            .frame(width: 68)
            .position(x: PANEL / 2 + 115 * CGFloat(cos(mid * .pi / 180)),
                      y: PANEL / 2 + 115 * CGFloat(sin(mid * .pi / 180)))
        }
        .frame(width: PANEL, height: PANEL)
        .scaleEffect(hot ? 1.04 : 1.0)
        .animation(.easeOut(duration: 0.08), value: hot)
    }
}

struct RadialView: View {
    @ObservedObject var m: RadialModel

    var body: some View {
        let n = max(m.actions.count, 1)
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.35))
                .overlay(Circle().fill(LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.03)],
                                                      startPoint: .topLeading, endPoint: .bottomTrailing)))
                .overlay(Circle().strokeBorder(glassRim, lineWidth: 1.2))
                .frame(width: 320, height: 320)

            ForEach(Array(m.actions.enumerated()), id: \.offset) { i, a in
                WedgeView(i: i, n: n, title: a.title, symbol: a.symbol, hot: m.hovered == i)
            }

            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.60))
                    .overlay(Circle().fill(Color.white.opacity(0.1)))
                    .overlay(Circle().strokeBorder(glassRim, lineWidth: 1.1))
                    .frame(width: 76, height: 76)
                
                Image(nsImage: m.thumb)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                
                Text(m.name)
                    .font(.system(size: 10, weight: .bold))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(4)
                    .offset(y: 36)
            }
        }
        .frame(width: PANEL, height: PANEL)
        .drawingGroup()
        .scaleEffect(m.shown ? 1.0 : 0.15)
        .opacity(m.shown ? 1.0 : 0.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.72), value: m.shown)
    }
}

// MARK: - Vista que recibe el drop
final class DropView: NSView {
    var model: RadialModel!
    var onClose: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func hoverIndex(_ sender: NSDraggingInfo) -> Int? {
        let p = convert(sender.draggingLocation, from: nil)
        let dx = Double(p.x - bounds.midX), dyUp = Double(p.y - bounds.midY)
        let r = hypot(dx, dyUp)
        guard r > 38, r < 165, !model.actions.isEmpty else { return nil }
        let step = 360.0 / Double(model.actions.count)
        let a = atan2(-dyUp, dx) * 180 / .pi
        var rel = (a + 90 + step / 2).truncatingRemainder(dividingBy: 360)
        if rel < 0 { rel += 360 }
        return Int(rel / step) % model.actions.count
    }
    
    private func update(_ s: NSDraggingInfo) -> NSDragOperation {
        let i = hoverIndex(s)
        if i != model.hovered { 
            model.hovered = i
            if i != nil { FX.tick() } 
        }
        return .copy
    }
    
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { update(s) }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation { update(s) }
    override func draggingExited(_ s: NSDraggingInfo?) { model.hovered = nil }
    override func prepareForDragOperation(_ s: NSDraggingInfo) -> Bool { model.hovered != nil }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        guard let i = model.hovered,
              let urls = s.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                          options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        let action = model.actions[i]
        DispatchQueue.main.async { action.run(urls) }
        return true
    }
    override func concludeDragOperation(_ s: NSDraggingInfo?) { onClose?() }
    override func draggingEnded(_ s: NSDraggingInfo) { onClose?() }
}

// MARK: - Controlador del menú radial
final class Radial {
    var panel: NSPanel?
    var model: RadialModel?
    var mode: Mode?

    func show(_ mode: Mode, urls: [URL], at mouse: NSPoint) {
        hide(animated: false)
        self.mode = mode
        let m = RadialModel()
        m.actions = { switch mode {
            case .convert: return convertActions(urls)
            case .tools: return toolActions(urls)
            case .share: return shareActions(urls) } }()
        m.name = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) archivos"
        
        m.thumb = NSWorkspace.shared.icon(forFile: urls[0].path)

        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main!
        var o = NSPoint(x: mouse.x - PANEL / 2, y: mouse.y - PANEL / 2)
        let f = screen.visibleFrame
        o.x = min(max(o.x, f.minX), f.maxX - PANEL)
        o.y = min(max(o.y, f.minY), f.maxY - PANEL)

        let p = NSPanel(contentRect: NSRect(origin: o, size: NSSize(width: PANEL, height: PANEL)),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.animationBehavior = .none
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.level = .popUpMenu; p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let drop = DropView(frame: NSRect(x: 0, y: 0, width: PANEL, height: PANEL))
        drop.model = m
        drop.onClose = { [weak self] in self?.hide() }
        let host = NSHostingView(rootView: RadialView(m: m))
        host.frame = drop.bounds; host.autoresizingMask = [.width, .height]
        drop.addSubview(host)
        p.contentView = drop
        p.orderFrontRegardless()
        panel = p
        model = m
        FX.open()
        
        if isImage(urls[0]) {
            let fileURL = urls[0]
            DispatchQueue.global(qos: .userInitiated).async {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 120
                ]
                if let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
                   let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                    let finalImg = NSImage(cgImage: cgThumb, size: NSSize(width: 40, height: 40))
                    DispatchQueue.main.async {
                        m.thumb = finalImg
                    }
                }
            }
        }
        
        DispatchQueue.main.async { m.shown = true }
    }

    func hide(animated: Bool = true) {
        let p = panel, m = model
        panel = nil; model = nil; mode = nil
        guard let p else { return }
        if animated, let m {
            m.shown = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { p.orderOut(nil) }
        } else {
            p.orderOut(nil)
        }
    }
}

// MARK: - App
final class AppDelegate: NSObject, NSApplicationDelegate {
    let radial = Radial()
    var item: NSStatusItem!
    var baseline = 0
    
    let availableSounds = ["Tink", "Glass", "Basso", "Pop", "Ping", "Hero", "Bottle", "Purr", "Submarine", "Funk", "Blow", "Frog"]

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = menuBarIcon()
        
        let menu = NSMenu()
        
        // --- ACTIVAR / DESACTIVAR MANDARINA ---
        let isAppEnabled = UserDefaults.standard.object(forKey: "app_enabled") as? Bool ?? true
        menu.addItem(toggle("Activar Mandarina", key: "app_enabled", on: isAppEnabled))
        menu.addItem(.separator())
        
        menu.addItem(toggle("Sonido activado", key: "sound", on: FX.soundOn))
        
        // Submenú para configurar sonidos
        let configMenu = NSMenu()
        
        let hoverItem = NSMenuItem(title: "Sonido al hacer Hover", action: nil, keyEquivalent: "")
        hoverItem.submenu = createSoundMenu(forKey: "sound_hover", current: FX.hoverSound)
        configMenu.addItem(hoverItem)
        
        let successItem = NSMenuItem(title: "Sonido de Acción Completada", action: nil, keyEquivalent: "")
        successItem.submenu = createSoundMenu(forKey: "sound_success", current: FX.successSound)
        configMenu.addItem(successItem)
        
        let errorItem = NSMenuItem(title: "Sonido de Error", action: nil, keyEquivalent: "")
        errorItem.submenu = createSoundMenu(forKey: "sound_error", current: FX.errorSound)
        configMenu.addItem(errorItem)
        
        let configMainItem = NSMenuItem(title: "Configurar sonidos...", action: nil, keyEquivalent: "")
        configMainItem.submenu = configMenu
        menu.addItem(configMainItem)
        
        menu.addItem(toggle("Respuesta Háptica", key: "haptic", on: FX.hapticOn))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Salir de Mandarina", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        item.menu = menu

        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged]) { [weak self] e in
            self?.handle(e)
        }
    }
    
    // Crea el submenú de sonidos para una clave específica
    func createSoundMenu(forKey key: String, current: String) -> NSMenu {
        let m = NSMenu()
        for soundName in availableSounds {
            let mi = NSMenuItem(title: soundName, action: #selector(changeSound(_:)), keyEquivalent: "")
            mi.target = self
            // Guardamos la clave y el nombre del sonido seleccionados separados por ":"
            mi.representedObject = "\(key):\(soundName)"
            if soundName == current { mi.state = .on }
            m.addItem(mi)
        }
        return m
    }
    
    // Función que se ejecuta al seleccionar un sonido del menú
    @objc func changeSound(_ sender: NSMenuItem) {
        guard let rep = sender.representedObject as? String else { return }
        let parts = rep.split(separator: ":")
        if parts.count == 2 {
            let key = String(parts[0])
            let soundName = String(parts[1])
            
            // Guardar configuración
            UserDefaults.standard.set(soundName, forKey: key)
            
            // Actualizar interfaz visual (checkmarks)
            if let menu = sender.menu {
                for item in menu.items { item.state = .off }
            }
            sender.state = .on
            
            // Reproducir el sonido para previsualizarlo (incluso si está en mute general para que sepas qué elegiste)
            if let s = NSSound(named: soundName) {
                s.volume = 0.5
                s.stop()
                s.play()
            }
        }
    }

    func toggle(_ title: String, key: String, on: Bool) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: #selector(flip(_:)), keyEquivalent: "")
        mi.target = self; mi.representedObject = key; mi.state = on ? .on : .off
        return mi
    }
    
    @objc func flip(_ s: NSMenuItem) {
        guard let k = s.representedObject as? String else { return }
        let current = UserDefaults.standard.object(forKey: k) as? Bool ?? true
        let new = !current
        UserDefaults.standard.set(new, forKey: k)
        s.state = new ? .on : .off
        if k == "sound" && new { FX.tick() }
    }

    func handle(_ e: NSEvent) {
        switch e.type {
        case .leftMouseDown: baseline = NSPasteboard(name: .drag).changeCount
        case .leftMouseUp: radial.hide()
        default: evaluate()
        }
    }

    func evaluate() {
        // --- NUEVO: Comprobar si Mandarina está encendida ---
        let isAppEnabled = UserDefaults.standard.object(forKey: "app_enabled") as? Bool ?? true
        guard isAppEnabled else { return }
        // -----------------------------------------------------

        guard NSEvent.pressedMouseButtons & 1 != 0 else { return }
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != baseline else { return }
        
        let f = NSEvent.modifierFlags
        let mode: Mode? = f.contains(.shift) ? .convert : f.contains(.command) ? .tools : f.contains(.control) ? .share : nil
        
        guard let mode else {
            if let p = radial.panel, !p.frame.contains(NSEvent.mouseLocation) { radial.hide() }
            return
        }
        
        if radial.mode != mode {
            let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            if !urls.isEmpty {
                radial.show(mode, urls: urls, at: NSEvent.mouseLocation)
            }
        }
    }
}

// build.sh usa esto para generar el icono de la app
_ = NSApplication.shared
if let i = CommandLine.arguments.firstIndex(of: "--iconset"), i + 1 < CommandLine.arguments.count {
    writeIconset(to: CommandLine.arguments[i + 1])
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()