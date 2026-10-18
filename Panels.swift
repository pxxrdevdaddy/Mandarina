import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImageIO

// MARK: - Componentes Auxiliares
struct ZoomOverlay: View {
    @Binding var zoom: CGFloat
    @Binding var pan: CGSize

    var body: some View {
        HStack(spacing: 8) {
            Button(action: { zoom = max(1.0, zoom - 0.25) }) {
                Image(systemName: "minus.magnifyingglass")
            }
            Text("\(Int(zoom * 100))%")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .frame(width: 42)
            Button(action: { zoom = min(5.0, zoom + 0.25) }) {
                Image(systemName: "plus.magnifyingglass")
            }
            if zoom != 1.0 || pan != .zero {
                Button("Restablecer") {
                    withAnimation {
                        zoom = 1.0
                        pan = .zero
                    }
                }
                .font(.caption)
            }
        }
        .padding(6)
        .background(.ultraThinMaterial)
        .cornerRadius(8)
        .padding(10)
    }
}

// MARK: - Ventanas flotantes genéricas
var openWindows: [NSWindow] = []

func showPanel<V: View>(title: String, size: NSSize, index: Int = 0, minSize: NSSize? = nil,
                        build: (@escaping () -> Void) -> V) {
    NSApp.activate(ignoringOtherApps: true)
    
    let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                    styleMask: [.titled, .closable, .resizable, .utilityWindow],
                    backing: .buffered, defer: true)
    p.animationBehavior = .documentWindow
    p.title = title
    p.level = .floating
    p.isReleasedWhenClosed = false
    p.hidesOnDeactivate = false
    p.contentView = NSHostingView(rootView: build({ [weak p] in p?.close() }))
    if let m = minSize { p.contentMinSize = m }
    p.setContentSize(size)
    p.center()
    if index > 0 {
        var f = p.frame
        f.origin.x += CGFloat(index) * 28; f.origin.y -= CGFloat(index) * 28
        p.setFrame(f, display: false)
    }
    NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { _ in
        openWindows.removeAll { $0 === p }
    }
    openWindows.append(p)
    p.makeKeyAndOrderFront(nil)
}

// MARK: - Inspector de metadatos
struct MetaRow { let key: String; let value: String }
struct MetaSection: Identifiable {
    let id = UUID()
    let title: String
    var rows: [MetaRow]
}
struct Coord { let lat: Double; let lon: Double }

func fmtValue(_ v: Any) -> String {
    if let a = v as? [Any] { return a.map(fmtValue).joined(separator: ", ") }
    if let d = v as? [String: Any] {
        return d.sorted { $0.key < $1.key }.map { "\($0.key): \(fmtValue($0.value))" }.joined(separator: "; ")
    }
    if let d = v as? Data { return "\(d.count) bytes" }
    return "\(v)"
}

func shellOutput(_ tool: String, _ args: [String]) -> String {
    let p = Process(); let pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
    p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

func loadMetadata(_ u: URL) -> (sections: [MetaSection], coord: Coord?) {
    var out: [MetaSection] = []
    var coord: Coord? = nil

    var file: [MetaRow] = [MetaRow(key: "Nombre", value: u.lastPathComponent), MetaRow(key: "Ruta", value: u.path)]
    if let t = utType(u)?.localizedDescription { file.append(MetaRow(key: "Tipo", value: t)) }
    if let a = try? FileManager.default.attributesOfItem(atPath: u.path) {
        if let s = (a[.size] as? NSNumber)?.int64Value {
            file.append(MetaRow(key: "Tamaño", value: ByteCountFormatter.string(fromByteCount: s, countStyle: .file)))
        }
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .medium
        if let d = a[.creationDate] as? Date { file.append(MetaRow(key: "Creado", value: df.string(from: d))) }
        if let d = a[.modificationDate] as? Date { file.append(MetaRow(key: "Modificado", value: df.string(from: d))) }
    }
    out.append(MetaSection(title: "Archivo", rows: file))

    if isImage(u), let s = CGImageSourceCreateWithURL(u as CFURL, nil),
       let props = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [String: Any] {
        var general: [MetaRow] = []
        var subs: [MetaSection] = []
        for (k, v) in props.sorted(by: { $0.key < $1.key }) {
            if let d = v as? [String: Any] {
                let name = k.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                var rows = d.sorted { $0.key < $1.key }.map { MetaRow(key: $0.key, value: fmtValue($0.value)) }
                if name == "GPS",
                   let la = d["Latitude"] as? Double, let lo = d["Longitude"] as? Double {
                    let lat = (d["LatitudeRef"] as? String) == "S" ? -la : la
                    let lon = (d["LongitudeRef"] as? String) == "W" ? -lo : lo
                    coord = Coord(lat: lat, lon: lon)
                    rows.insert(MetaRow(key: "Coordenadas", value: String(format: "%.6f, %.6f", lat, lon)), at: 0)
                }
                subs.append(MetaSection(title: name, rows: rows))
            } else {
                general.append(MetaRow(key: k, value: fmtValue(v)))
            }
        }
        if !general.isEmpty { out.append(MetaSection(title: "General", rows: general)) }
        let order = ["Exif", "TIFF", "GPS", "IPTC", "MakerApple"]
        subs.sort {
            let a = order.firstIndex(of: $0.title) ?? 99, b = order.firstIndex(of: $1.title) ?? 99
            return a == b ? $0.title < $1.title : a < b
        }
        out.append(contentsOf: subs)
    } else {
        var rows: [MetaRow] = []
        for line in shellOutput("/usr/bin/mdls", [u.path]).split(separator: "\n", omittingEmptySubsequences: true) {
            let l = String(line)
            if let r = l.range(of: " = "), l.hasPrefix("kMDItem") {
                let key = String(l[l.startIndex..<r.lowerBound]).replacingOccurrences(of: "kMDItem", with: "").trimmingCharacters(in: .whitespaces)
                rows.append(MetaRow(key: key, value: String(l[r.upperBound...])))
            } else if !rows.isEmpty {
                let last = rows.removeLast()
                rows.append(MetaRow(key: last.key, value: last.value + " " + l.trimmingCharacters(in: .whitespaces)))
            }
        }
        if !rows.isEmpty { out.append(MetaSection(title: "Spotlight", rows: rows)) }
    }
    return (out, coord)
}

struct MetadataView: View {
    let url: URL
    @State private var sections: [MetaSection] = []
    @State private var coord: Coord? = nil
    @State private var query = ""
    @State private var status = ""
    @State private var displayIcon: NSImage? = nil

    private var isImg: Bool { isImage(url) }
    private var hasGPS: Bool { sections.contains { $0.title == "GPS" } }
    private var total: Int { sections.reduce(0) { $0 + $1.rows.count } }
    private var filtered: [MetaSection] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return sections }
        return sections.compactMap { s in
            var c = s
            if !s.title.lowercased().contains(q) {
                c.rows = s.rows.filter { $0.key.lowercased().contains(q) || $0.value.lowercased().contains(q) }
            }
            return c.rows.isEmpty ? nil : c
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let icon = displayIcon {
                    Image(nsImage: icon)
                        .resizable().scaledToFit().frame(width: 40, height: 40).cornerRadius(6)
                } else {
                    Color.clear.frame(width: 40, height: 40)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent).font(.headline).lineLimit(1)
                    Text("\(total) campos").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                TextField("Buscar", text: $query).textFieldStyle(.roundedBorder).frame(width: 170)
            }.padding(12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(filtered) { s in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(s.title.uppercased()).font(.system(size: 10, weight: .bold)).foregroundColor(.orange)
                            ForEach(Array(s.rows.enumerated()), id: \.offset) { _, r in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(r.key).foregroundColor(.secondary).frame(width: 150, alignment: .leading)
                                    Text(r.value).textSelection(.enabled)
                                    Spacer(minLength: 0)
                                }.font(.system(size: 12))
                            }
                        }
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 8) {
                if let c = coord {
                    Button("Abrir en Mapas") {
                        if let u = URL(string: "https://maps.apple.com/?ll=\(c.lat),\(c.lon)") { NSWorkspace.shared.open(u) }
                    }
                }
                Button("Copiar todo") {
                    let txt = sections.map { s in "[\(s.title)]\n" + s.rows.map { "\($0.key): \($0.value)" }.joined(separator: "\n") }
                        .joined(separator: "\n\n")
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(txt, forType: .string)
                    status = "Copiado"; FX.done(true)
                }
                Spacer()
                Text(status).font(.caption).foregroundColor(.secondary)
                Button("Quitar GPS (copia)") { strip(gpsOnly: true) }.disabled(!isImg || !hasGPS)
                Button("Quitar todo (copia)") { strip(gpsOnly: false) }.disabled(!isImg)
            }.padding(10)
        }
        .frame(minWidth: 520, minHeight: 380)
        .onAppear {
            DispatchQueue.global(qos: .userInitiated).async {
                let r = loadMetadata(url)
                let icon = (isImg ? NSImage(contentsOf: url) : nil) ?? NSWorkspace.shared.icon(forFile: url.path)
                
                DispatchQueue.main.async {
                    self.sections = r.sections
                    self.coord = r.coord
                    self.displayIcon = icon
                }
            }
        }
    }

    private func strip(gpsOnly: Bool) {
        let u = url
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = stripMetadata(u, gpsOnly: gpsOnly)
            DispatchQueue.main.async { status = ok ? "Copia guardada junto al original" : "No se pudo guardar"; FX.done(ok) }
        }
    }
}

func openMetadata(_ u: URL, index: Int = 0) {
    showPanel(title: "Metadatos — \(u.lastPathComponent)", size: NSSize(width: 580, height: 560),
              index: index, minSize: NSSize(width: 520, height: 380)) { _ in MetadataView(url: u) }
}

// MARK: - Editor de recorte
enum RatioChoice: String, CaseIterable, Identifiable {
    case free = "Libre", original = "Original", sq = "1:1", r43 = "4:3", r32 = "3:2", r169 = "16:9", r54 = "5:4", r21 = "2:1"
    var id: String { rawValue }
}
enum Handle { case none, move, tl, t, tr, r, br, b, bl, l }

func loadOrientedImage(_ u: URL, maxPixel: Int? = nil) -> (CGImage, CFString)? {
    guard let s = CGImageSourceCreateWithURL(u as CFURL, nil), let type = CGImageSourceGetType(s) else { return nil }
    let props = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any]
    let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 4096
    let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 4096
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: min(maxPixel ?? Int.max, max(w, h)),
        kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let img = CGImageSourceCreateThumbnailAtIndex(s, 0, opts as CFDictionary) else { return nil }
    return (img, type)
}

func applyCrop(_ h: Handle, _ r0: CGRect, dx: CGFloat, dy: CGFloat, W: CGFloat, H: CGFloat, ratio: CGFloat?) -> CGRect {
    let minS: CGFloat = 24
    if h == .none { return r0 }
    if h == .move {
        var r = r0.offsetBy(dx: dx, dy: dy)
        r.origin.x = min(max(r.origin.x, 0), W - r.width)
        r.origin.y = min(max(r.origin.y, 0), H - r.height)
        return r
    }
    var l = r0.minX, rt = r0.maxX, t = r0.minY, b = r0.maxY
    switch h {
    case .tl: l += dx; t += dy
    case .t: t += dy
    case .tr: rt += dx; t += dy
    case .r: rt += dx
    case .br: rt += dx; b += dy
    case .b: b += dy
    case .bl: l += dx; b += dy
    case .l: l += dx
    default: break
    }
    guard let ratio else {
        l = max(0, min(l, rt - minS)); rt = min(W, max(rt, l + minS))
        t = max(0, min(t, b - minS)); b = min(H, max(b, t + minS))
        return CGRect(x: l, y: t, width: rt - l, height: b - t)
    }
    switch h {
    case .tl, .tr, .bl, .br:
        let left = (h == .tl || h == .bl), top = (h == .tl || h == .tr)
        let ax = left ? r0.maxX : r0.minX, ay = top ? r0.maxY : r0.minY
        let dirX: CGFloat = left ? -1 : 1, dirY: CGFloat = top ? -1 : 1
        let wRaw = max(0, ((left ? l : rt) - ax) * dirX)
        let hRaw = max(0, ((top ? t : b) - ay) * dirY)
        var w = max(minS, wRaw, hRaw * ratio)
        let roomX = dirX > 0 ? W - ax : ax, roomY = dirY > 0 ? H - ay : ay
        w = min(w, roomX, roomY * ratio)
        let hh = w / ratio
        return CGRect(x: dirX > 0 ? ax : ax - w, y: dirY > 0 ? ay : ay - hh, width: w, height: hh)
    case .l, .r:
        let left = (h == .l)
        let ax = left ? r0.maxX : r0.minX, dirX: CGFloat = left ? -1 : 1
        var w = max(minS, ((left ? l : rt) - ax) * dirX)
        let cy = r0.midY
        let roomX = dirX > 0 ? W - ax : ax, roomY = 2 * min(cy, H - cy)
        w = min(w, roomX, roomY * ratio)
        let hh = w / ratio
        return CGRect(x: dirX > 0 ? ax : ax - w, y: cy - hh / 2, width: w, height: hh)
    default:
        let top = (h == .t)
        let ay = top ? r0.maxY : r0.minY, dirY: CGFloat = top ? -1 : 1
        var hh = max(minS, ((top ? t : b) - ay) * dirY)
        let cx = r0.midX
        let roomY = dirY > 0 ? H - ay : ay, roomX = 2 * min(cx, W - cx)
        hh = min(hh, roomY, roomX / ratio)
        let w = hh * ratio
        return CGRect(x: cx - w / 2, y: dirY > 0 ? ay : ay - hh, width: w, height: hh)
    }
}

struct CropView: View {
    let url: URL
    let cg: CGImage
    let type: CFString
    let close: () -> Void
    private let nsImg: NSImage

    @State private var rect: CGRect
    @State private var choice: RatioChoice = .free
    @State private var flipped = false
    @State private var dragging = false
    @State private var handle: Handle = .none
    @State private var startRect: CGRect = .zero
    @State private var status = ""
    @State private var zoomScale: CGFloat = 1.0
    @State private var lastZoomScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero

    init(url: URL, cg: CGImage, type: CFString, close: @escaping () -> Void) {
        self.url = url; self.cg = cg; self.type = type; self.close = close
        self.nsImg = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        _rect = State(initialValue: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    }

    private var W: CGFloat { CGFloat(cg.width) }
    private var H: CGFloat { CGFloat(cg.height) }
    private var ratio: CGFloat? {
        var r: CGFloat
        switch choice {
        case .free: return nil
        case .original: r = W / H
        case .sq: r = 1
        case .r43: r = 4.0 / 3
        case .r32: r = 3.0 / 2
        case .r169: r = 16.0 / 9
        case .r54: r = 5.0 / 4
        case .r21: r = 2
        }
        return flipped ? 1 / r : r
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Proporción", selection: $choice) {
                    ForEach(RatioChoice.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.menu).frame(width: 190)
                Button { flipped.toggle() } label: { Image(systemName: "rotate.right") }
                    .help("Girar proporción (horizontal / vertical)")
                    .disabled(choice == .free || choice == .sq)
                Button("Restablecer") { 
                    choice = .free; flipped = false
                    rect = CGRect(x: 0, y: 0, width: W, height: H)
                    zoomScale = 1.0; lastZoomScale = 1.0; panOffset = .zero
                }
                Spacer()
                Text("\(Int(rect.width)) × \(Int(rect.height)) px").font(.system(size: 12, design: .monospaced)).foregroundColor(.secondary)
            }.padding(10)
            Divider()
            
            ZStack(alignment: .bottomLeading) {
                canvas.background(Color.black)
                ZoomOverlay(zoom: $zoomScale, pan: $panOffset)
            }
            
            Divider()
            HStack {
                Text(status).font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("Cancelar") { close() }.keyboardShortcut(.cancelAction)
                Button("Guardar copia") { save() }.keyboardShortcut(.defaultAction)
            }.padding(10)
        }
        .frame(minWidth: 560, minHeight: 440)
        .onChange(of: choice) { fitRatio() }
        .onChange(of: flipped) { fitRatio() }
    }

    private var canvas: some View {
        GeometryReader { geo in
            let s = max(0.01, min((geo.size.width - 24) / W, (geo.size.height - 24) / H))
            let dw = W * s, dh = H * s
            let ox = (geo.size.width - dw) / 2, oy = (geo.size.height - dh) / 2
            let vr = CGRect(x: ox + rect.minX * s, y: oy + rect.minY * s, width: rect.width * s, height: rect.height * s)
            
            ZStack(alignment: .topLeading) {
                Image(nsImage: nsImg).resizable().interpolation(.none).frame(width: dw, height: dh).offset(x: ox, y: oy)
                Path { p in
                    p.addRect(CGRect(x: ox, y: oy, width: dw, height: dh))
                    p.addRect(vr)
                }.fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                Path { p in
                    for i in 1...2 {
                        let x = vr.minX + vr.width * CGFloat(i) / 3, y = vr.minY + vr.height * CGFloat(i) / 3
                        p.move(to: CGPoint(x: x, y: vr.minY)); p.addLine(to: CGPoint(x: x, y: vr.maxY))
                        p.move(to: CGPoint(x: vr.minX, y: y)); p.addLine(to: CGPoint(x: vr.maxX, y: y))
                    }
                }.stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                Rectangle().stroke(Color.white, lineWidth: 1.5).frame(width: vr.width, height: vr.height).offset(x: vr.minX, y: vr.minY)
                ForEach(0..<8, id: \.self) { i in
                    let pts: [(CGFloat, CGFloat)] = [(0, 0), (0.5, 0), (1, 0), (1, 0.5), (1, 1), (0.5, 1), (0, 1), (0, 0.5)]
                    Rectangle().fill(Color.white).frame(width: 9, height: 9)
                        .shadow(color: .black.opacity(0.5), radius: 1)
                        .position(x: vr.minX + vr.width * pts[i].0, y: vr.minY + vr.height * pts[i].1)
                }
            }
            .scaleEffect(zoomScale)
            .offset(panOffset)
            .drawingGroup()
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { val in
                        zoomScale = max(1.0, min(lastZoomScale * val, 5.0))
                    }
                    .onEnded { _ in
                        lastZoomScale = zoomScale
                    }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let startPoint = CGPoint(
                            x: (v.startLocation.x - geo.size.width / 2 - panOffset.width) / zoomScale + geo.size.width / 2,
                            y: (v.startLocation.y - geo.size.height / 2 - panOffset.height) / zoomScale + geo.size.height / 2
                        )
                        if !dragging {
                            dragging = true
                            startRect = rect
                            handle = hit(startPoint, vr)
                        }
                        guard handle != .none else { return }
                        let scaledDx = v.translation.width / (s * zoomScale)
                        let scaledDy = v.translation.height / (s * zoomScale)
                        rect = applyCrop(handle, startRect, dx: scaledDx, dy: scaledDy, W: W, H: H, ratio: ratio)
                    }
                    .onEnded { _ in dragging = false; handle = .none }
            )
        }
    }

    private func hit(_ p: CGPoint, _ r: CGRect) -> Handle {
        let t: CGFloat = 18
        let nl = abs(p.x - r.minX) < t, nr = abs(p.x - r.maxX) < t
        let nt = abs(p.y - r.minY) < t, nb = abs(p.y - r.maxY) < t
        let inX = p.x > r.minX - t && p.x < r.maxX + t, inY = p.y > r.minY - t && p.y < r.maxY + t
        if nl && nt { return .tl }; if nr && nt { return .tr }
        if nl && nb { return .bl }; if nr && nb { return .br }
        if nt && inX { return .t }; if nb && inX { return .b }
        if nl && inY { return .l }; if nr && inY { return .r }
        if r.contains(p) { return .move }
        return .none
    }

    private func fitRatio() {
        guard let r = ratio else { return }
        let w = min(W, H * r), h = w / r
        let x = min(max(rect.midX - w / 2, 0), W - w), y = min(max(rect.midY - h / 2, 0), H - h)
        rect = CGRect(x: x, y: y, width: w, height: h)
    }

    private func save() {
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: W, height: H))
        guard let c = cg.cropping(to: r) else { status = "No se pudo recortar"; FX.done(false); return }
        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        var utiType = type, ext = url.pathExtension
        if !writable.contains(type as String) || ext.isEmpty { utiType = UTType.png.identifier as CFString; ext = "png" }
        let out = uniqueURL(url, suffix: " recorte", ext: ext)
        guard let d = CGImageDestinationCreateWithURL(out as CFURL, utiType, 1, nil) else { status = "No se pudo guardar"; FX.done(false); return }
        CGImageDestinationAddImage(d, c, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        let ok = CGImageDestinationFinalize(d)
        status = ok ? "Guardado: \(out.lastPathComponent)" : "No se pudo guardar"
        FX.done(ok)
        if ok { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { close() } }
    }
}

func openCrop(_ urls: [URL]) {
    let validUrls = urls.filter { isImage($0) }.prefix(5)
    if validUrls.isEmpty { FX.done(false); return }
    
    for (index, u) in validUrls.enumerated() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let (img, type) = loadOrientedImage(u) else { return }
            
            DispatchQueue.main.async {
                showPanel(title: "Recortar — \(u.lastPathComponent)", size: NSSize(width: 780, height: 620),
                          index: index, minSize: NSSize(width: 560, height: 440)) { close in
                    CropView(url: u, cg: img, type: type, close: close)
                }
            }
        }
    }
}

// MARK: - Documento (docx, doc, rtf, html, odt, txt) → PDF
func docToPDF(_ u: URL) -> Bool {
    guard let attr = try? NSAttributedString(url: u, options: [:], documentAttributes: nil) else { return false }
    let out = uniqueURL(u, ext: "pdf")

    let info = NSPrintInfo()
    info.paperSize = NSSize(width: 595, height: 842)
    info.topMargin = 56; info.bottomMargin = 56; info.leftMargin = 56; info.rightMargin = 56
    info.isHorizontallyCentered = false; info.isVerticallyCentered = false
    info.jobDisposition = .save
    info.dictionary().setObject(out, forKey: NSPrintInfo.AttributeKey.jobSavingURL.rawValue as NSString)

    let width = info.paperSize.width - info.leftMargin - info.rightMargin
    let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
    tv.appearance = NSAppearance(named: .aqua)
    tv.drawsBackground = false
    tv.isHorizontallyResizable = false
    tv.isVerticallyResizable = true
    tv.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
    tv.textContainer?.widthTracksTextView = true
    tv.textStorage?.setAttributedString(attr)
    if let lm = tv.layoutManager, let tc = tv.textContainer {
        lm.ensureLayout(for: tc)
        tv.frame = NSRect(x: 0, y: 0, width: width, height: ceil(lm.usedRect(for: tc).height) + 1)
    }

    let op = NSPrintOperation(view: tv, printInfo: info)
    op.showsPrintPanel = false
    op.showsProgressPanel = false
    return op.run() && FileManager.default.fileExists(atPath: out.path)
}