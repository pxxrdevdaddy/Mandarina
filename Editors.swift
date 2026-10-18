import AppKit
import SwiftUI
import CoreImage
import UniformTypeIdentifiers
import QuickLookThumbnailing
import ImageIO

// MARK: - Utilidades compartidas
let ciContext = CIContext()

func renderCI(_ ci: CIImage) -> CGImage? { ciContext.createCGImage(ci, from: ci.extent) }

func renderToCG<V: View>(_ v: V) -> CGImage? {
    MainActor.assumeIsolated {
        let r = ImageRenderer(content: v)
        r.scale = 1
        return r.cgImage
    }
}

func toNS(_ cg: CGImage) -> NSImage { NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }

func rectFrom(_ a: CGPoint, _ b: CGPoint) -> CGRect {
    CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
}

func fitMetrics(_ box: CGSize, _ content: CGSize, margin: CGFloat = 16) -> (s: CGFloat, ox: CGFloat, oy: CGFloat) {
    let s = max(0.01, min((box.width - 2 * margin) / content.width, (box.height - 2 * margin) / content.height))
    return (s, (box.width - content.width * s) / 2, (box.height - content.height * s) / 2)
}

func saveImage(_ cg: CGImage, near url: URL, suffix: String, preferPNG: Bool = false) -> URL? {
    var uti: CFString = UTType.png.identifier as CFString
    var ext = "png"
    if !preferPNG, !url.pathExtension.isEmpty,
       let s = CGImageSourceCreateWithURL(url as CFURL, nil), let t = CGImageSourceGetType(s),
       ((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []).contains(t as String) {
        uti = t; ext = url.pathExtension
    }
    let out = uniqueURL(url, suffix: suffix, ext: ext)
    guard let d = CGImageDestinationCreateWithURL(out as CFURL, uti, 1, nil) else { return nil }
    CGImageDestinationAddImage(d, cg, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
    return CGImageDestinationFinalize(d) ? out : nil
}

func openImageEditor<V: View>(_ urls: [URL], title: String, size: NSSize, minSize: NSSize, maxPixel: Int? = nil,
                              content: @escaping (URL, CGImage, @escaping () -> Void) -> V) {
    var opened = 0
    for u in urls where isImage(u) {
        guard opened < 5, let (img, _) = loadOrientedImage(u, maxPixel: maxPixel) else { continue }
        showPanel(title: "\(title) — \(u.lastPathComponent)", size: size, index: opened, minSize: minSize) { close in
            content(u, img, close)
        }
        opened += 1
    }
    if opened == 0 { FX.done(false) }
}

struct EditorFooter: View {
    let status: String
    let close: () -> Void
    let save: () -> Void
    var body: some View {
        HStack {
            Text(status).font(.caption).foregroundColor(.secondary)
            Spacer()
            Button("Cancelar", action: close).keyboardShortcut(.cancelAction)
            Button("Guardar copia", action: save).keyboardShortcut(.defaultAction)
        }.padding(10)
    }
}

// MARK: - Componente de Zoom interactivo para visores
struct ZoomableImageView: View {
    let image: NSImage
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0

    var body: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .frame(width: geo.size.width * max(1, scale), height: geo.size.height * max(1, scale))
                    .gesture(
                        MagnificationGesture()
                            .onChanged { val in
                                scale = max(1.0, min(lastScale * val, 5.0))
                            }
                            .onEnded { _ in
                                lastScale = scale
                            }
                    )
            }
        }
        .background(Color.black.opacity(0.85))
    }
}

// MARK: - EDIT (ajustes de imagen)
struct EditParams: Equatable {
    var brightness = 0.0, contrast = 1.0, saturation = 1.0, exposure = 0.0
    var warmth = 0.0, sharpness = 0.0, vignette = 0.0
    var preset = "Ninguno"
    var rotation = 0
    var flip = false
}

let editPresets: [(name: String, filter: String?)] = [
    ("Ninguno", nil), ("Mono", "CIPhotoEffectMono"), ("Noir", "CIPhotoEffectNoir"), ("Sepia", "CISepiaTone"),
    ("Chrome", "CIPhotoEffectChrome"), ("Desvaído", "CIPhotoEffectFade"), ("Instantánea", "CIPhotoEffectInstant"),
]

func applyEdit(_ input: CIImage, _ p: EditParams) -> CIImage {
    let extent = input.extent
    var img = input
    if p.exposure != 0 { img = img.applyingFilter("CIExposureAdjust", parameters: ["inputEV": p.exposure]) }
    img = img.applyingFilter("CIColorControls", parameters: [
        "inputBrightness": p.brightness, "inputContrast": p.contrast, "inputSaturation": p.saturation,
    ])
    if p.warmth != 0 {
        img = img.applyingFilter("CITemperatureAndTint", parameters: [
            "inputNeutral": CIVector(x: CGFloat(6500 + p.warmth * 2000), y: 0),
            "inputTargetNeutral": CIVector(x: 6500, y: 0),
        ])
    }
    if p.sharpness > 0 { img = img.applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": p.sharpness]) }
    if let f = editPresets.first(where: { $0.name == p.preset })?.filter { img = img.applyingFilter(f) }
    if p.vignette > 0 {
        img = img.applyingFilter("CIVignette", parameters: ["inputIntensity": p.vignette, "inputRadius": 1.5])
    }
    img = img.cropped(to: extent)
    if p.flip { img = img.oriented(.upMirrored) }
    let o: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
    img = img.oriented(o[((p.rotation % 4) + 4) % 4])
    let e = img.extent
    return img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
}

struct EditView: View {
    let url: URL
    let close: () -> Void
    private let base: CIImage
    @State private var p = EditParams()
    @State private var preview: NSImage
    @State private var status = ""

    init(url: URL, cg: CGImage, close: @escaping () -> Void) {
        self.url = url; self.close = close
        self.base = CIImage(cgImage: cg)
        _preview = State(initialValue: toNS(cg))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ZoomableImageView(image: preview)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Filtro", selection: $p.preset) {
                            ForEach(editPresets, id: \.name) { Text($0.name).tag($0.name) }
                        }.pickerStyle(.menu)
                        row("Exposición", $p.exposure, -2...2)
                        row("Brillo", $p.brightness, -0.5...0.5)
                        row("Contraste", $p.contrast, 0.5...1.5)
                        row("Saturación", $p.saturation, 0...2)
                        row("Calidez", $p.warmth, -1...1)
                        row("Nitidez", $p.sharpness, 0...2)
                        row("Viñeta", $p.vignette, 0...2)
                        HStack {
                            Button { p.rotation = (p.rotation + 3) % 4 } label: { Image(systemName: "rotate.left") }
                            Button { p.rotation = (p.rotation + 1) % 4 } label: { Image(systemName: "rotate.right") }
                            Button { p.flip.toggle() } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                            Spacer()
                            Button("Restablecer") { p = EditParams() }
                        }
                    }.padding(12)
                }.frame(width: 240)
            }
            Divider()
            EditorFooter(status: status, close: close, save: save)
        }
        .frame(minWidth: 700, minHeight: 480)
        .onChange(of: p) {
            if let o = renderCI(applyEdit(base, p)) { preview = toNS(o) }
        }
    }

    private func row(_ t: String, _ v: Binding<Double>, _ r: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(t); Spacer()
                Text(String(format: "%.2f", v.wrappedValue)).foregroundColor(.secondary)
            }.font(.system(size: 11))
            Slider(value: v, in: r)
        }
    }

    private func save() {
        guard let full = loadOrientedImage(url)?.0,
              let out = renderCI(applyEdit(CIImage(cgImage: full), p)),
              let u = saveImage(out, near: url, suffix: " editado") else {
            status = "No se pudo guardar"; FX.done(false); return
        }
        status = "Guardado: \(u.lastPathComponent)"; FX.done(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { close() }
    }
}

func openEdit(_ urls: [URL]) {
    openImageEditor(urls, title: "Editar", size: NSSize(width: 900, height: 620), minSize: NSSize(width: 700, height: 480),
                    maxPixel: 1400) { u, cg, close in EditView(url: u, cg: cg, close: close) }
}

// MARK: - ANNOTATE (dibujar sobre la imagen)
enum AnnotTool: String, CaseIterable, Identifiable {
    case pen = "Lápiz", highlighter = "Resaltador", arrow = "Flecha", rect = "Rectángulo", ellipse = "Elipse", text = "Texto"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .arrow: return "arrow.up.right"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .text: return "textformat"
        }
    }
}

struct Annot: Identifiable {
    let id = UUID()
    var tool: AnnotTool
    var points: [CGPoint]
    var color: Color
    var width: CGFloat
    var text: String = ""
}

func drawAnnot(_ a: Annot, in ctx: inout GraphicsContext) {
    let p0 = a.points.first ?? .zero
    let p1 = a.points.last ?? p0
    switch a.tool {
    case .pen, .highlighter:
        var path = Path()
        path.move(to: p0)
        if a.points.count == 1 { path.addLine(to: CGPoint(x: p0.x + 0.01, y: p0.y)) }
        for q in a.points.dropFirst() { path.addLine(to: q) }
        let hl = a.tool == .highlighter
        ctx.stroke(path, with: .color(hl ? a.color.opacity(0.35) : a.color),
                   style: StrokeStyle(lineWidth: hl ? a.width * 3.5 : a.width, lineCap: .round, lineJoin: .round))
    case .rect:
        ctx.stroke(Path(roundedRect: rectFrom(p0, p1), cornerRadius: a.width), with: .color(a.color), lineWidth: a.width)
    case .ellipse:
        ctx.stroke(Path(ellipseIn: rectFrom(p0, p1)), with: .color(a.color), lineWidth: a.width)
    case .arrow:
        var path = Path()
        path.move(to: p0); path.addLine(to: p1)
        let ang = atan2(p1.y - p0.y, p1.x - p0.x)
        let head = max(a.width * 4.5, 14)
        for d in [0.5, -0.5] {
            path.move(to: p1)
            path.addLine(to: CGPoint(x: p1.x - head * CGFloat(cos(ang + d)), y: p1.y - head * CGFloat(sin(ang + d))))
        }
        ctx.stroke(path, with: .color(a.color), style: StrokeStyle(lineWidth: a.width, lineCap: .round, lineJoin: .round))
    case .text:
        ctx.draw(Text(a.text).font(.system(size: max(a.width * 6, 12), weight: .bold)).foregroundColor(a.color),
                 at: p0, anchor: .topLeading)
    }
}

struct AnnotLayer: View {
    let items: [Annot]
    let pixel: CGSize
    var body: some View {
        Canvas { ctx, size in
            let s = size.width / pixel.width
            ctx.scaleBy(x: s, y: s)
            for a in items { drawAnnot(a, in: &ctx) }
        }
    }
}

struct AnnotateView: View {
    let url: URL
    let cg: CGImage
    let close: () -> Void
    private let nsImg: NSImage

    @State private var items: [Annot] = []
    @State private var current: Annot? = nil
    @State private var tool: AnnotTool = .pen
    @State private var color: Color = .red
    @State private var thickness: Double = 4
    @State private var textInput = "Texto"
    @State private var status = ""

    init(url: URL, cg: CGImage, close: @escaping () -> Void) {
        self.url = url; self.cg = cg; self.close = close
        self.nsImg = toNS(cg)
    }

    private var W: CGFloat { CGFloat(cg.width) }
    private var H: CGFloat { CGFloat(cg.height) }
    private var lineWidth: CGFloat { CGFloat(thickness) * max(W, H) / 1000 }
    private let swatches: [Color] = [.red, .orange, .yellow, .green, .blue, .black, .white]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(AnnotTool.allCases) { t in
                    Button { tool = t } label: { Image(systemName: t.symbol) }
                        .buttonStyle(.bordered).tint(tool == t ? Color.orange : nil).help(t.rawValue)
                }
                Divider().frame(height: 18)
                ForEach(0..<swatches.count, id: \.self) { i in
                    Circle().fill(swatches[i]).frame(width: 16, height: 16)
                        .overlay(Circle().stroke(Color.gray.opacity(0.6), lineWidth: 0.5))
                        .onTapGesture { color = swatches[i] }
                }
                ColorPicker("", selection: $color).labelsHidden()
                Slider(value: $thickness, in: 1...14).frame(width: 90)
                if tool == .text { TextField("Texto", text: $textInput).textFieldStyle(.roundedBorder).frame(width: 130) }
                Spacer()
                Button { if !items.isEmpty { items.removeLast() } } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(items.isEmpty).help("Deshacer")
                Button("Borrar todo") { items.removeAll() }.disabled(items.isEmpty)
            }.padding(10)
            Divider()
            canvas.background(Color.black.opacity(0.85))
            Divider()
            EditorFooter(status: status, close: close, save: save)
        }
        .frame(minWidth: 640, minHeight: 460)
    }

    private var canvas: some View {
        GeometryReader { geo in
            let m = fitMetrics(geo.size, CGSize(width: W, height: H))
            let dw = W * m.s, dh = H * m.s
            ZStack(alignment: .topLeading) {
                Image(nsImage: nsImg).resizable().frame(width: dw, height: dh).offset(x: m.ox, y: m.oy)
                AnnotLayer(items: items + (current.map { [$0] } ?? []), pixel: CGSize(width: W, height: H))
                    .frame(width: dw, height: dh).offset(x: m.ox, y: m.oy)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let p = CGPoint(x: (v.location.x - m.ox) / m.s, y: (v.location.y - m.oy) / m.s)
                    if current == nil {
                        let s0 = CGPoint(x: (v.startLocation.x - m.ox) / m.s, y: (v.startLocation.y - m.oy) / m.s)
                        current = Annot(tool: tool, points: [s0], color: color, width: lineWidth, text: textInput)
                    }
                    guard var c = current else { return }
                    if c.tool == .pen || c.tool == .highlighter { c.points.append(p) }
                    else if c.tool != .text {
                        if c.points.count == 1 { c.points.append(p) } else { c.points[1] = p }
                    }
                    current = c
                }
                .onEnded { _ in
                    if let c = current {
                        if c.tool == .text { if !c.text.isEmpty { items.append(c) } }
                        else if c.tool == .pen || c.tool == .highlighter || c.points.count > 1 { items.append(c) }
                    }
                    current = nil
                })
        }
    }

    private func save() {
        let size = CGSize(width: W, height: H)
        let v = ZStack(alignment: .topLeading) {
            Image(nsImage: nsImg).resizable().frame(width: W, height: H)
            AnnotLayer(items: items, pixel: size).frame(width: W, height: H)
        }.frame(width: W, height: H)
        guard let out = renderToCG(v), let u = saveImage(out, near: url, suffix: " anotado") else {
            status = "No se pudo guardar"; FX.done(false); return
        }
        status = "Guardado: \(u.lastPathComponent)"; FX.done(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { close() }
    }
}

func openAnnotate(_ urls: [URL]) {
    openImageEditor(urls, title: "Anotar", size: NSSize(width: 860, height: 640), minSize: NSSize(width: 640, height: 460),
                    maxPixel: 4000) { u, cg, close in AnnotateView(url: u, cg: cg, close: close) }
}

// MARK: - REDACT (tapar zonas: pixelar / difuminar / negro)
enum RedactMode: String, CaseIterable, Identifiable {
    case pixel = "Pixelar", blur = "Difuminar", black = "Negro"
    var id: String { rawValue }
}

func redactImage(_ cg: CGImage, regions: [CGRect], mode: RedactMode, amount: Double) -> CGImage? {
    let W = CGFloat(cg.width), H = CGFloat(cg.height)
    let base = CIImage(cgImage: cg)
    let full = base.extent
    let maxDim = max(W, H)
    let block = max(4, maxDim / 400 * CGFloat(amount))
    let radius = max(2, maxDim / 300 * CGFloat(amount))
    var result = base
    for r in regions {
        let rect = CGRect(x: r.minX * W, y: (1 - r.maxY) * H, width: r.width * W, height: r.height * H)
            .integral.intersection(full)
        if rect.isEmpty { continue }
        let piece: CIImage
        switch mode {
        case .pixel:
            piece = base.applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: block, kCIInputCenterKey: CIVector(x: rect.minX, y: rect.minY),
            ]).cropped(to: rect)
        case .blur:
            piece = base.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: rect)
        case .black:
            piece = CIImage(color: CIColor.black).cropped(to: rect)
        }
        result = piece.composited(over: result)
    }
    return ciContext.createCGImage(result, from: full)
}

struct RedactView: View {
    let url: URL
    let cg: CGImage
    let close: () -> Void

    @State private var regions: [CGRect] = []
    @State private var drag: CGRect? = nil
    @State private var mode: RedactMode = .pixel
    @State private var amount: Double = 5
    @State private var preview: NSImage
    @State private var status = ""

    init(url: URL, cg: CGImage, close: @escaping () -> Void) {
        self.url = url; self.cg = cg; self.close = close
        _preview = State(initialValue: toNS(cg))
    }

    private var W: CGFloat { CGFloat(cg.width) }
    private var H: CGFloat { CGFloat(cg.height) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $mode) { ForEach(RedactMode.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 240).labelsHidden()
                Text("Intensidad").font(.caption).foregroundColor(.secondary)
                Slider(value: $amount, in: 1...10).frame(width: 120).disabled(mode == .black)
                Spacer()
                Button { if !regions.isEmpty { regions.removeLast() } } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(regions.isEmpty)
                Button("Limpiar") { regions.removeAll() }.disabled(regions.isEmpty)
            }.padding(10)
            Divider()
            canvas.background(Color.black.opacity(0.85))
            Divider()
            EditorFooter(status: status.isEmpty ? "Arrastra sobre la imagen para tapar zonas" : status, close: close, save: save)
        }
        .frame(minWidth: 640, minHeight: 460)
        .onChange(of: regions) { refresh() }
        .onChange(of: mode) { refresh() }
        .onChange(of: amount) { refresh() }
    }

    private func refresh() {
        if regions.isEmpty { preview = toNS(cg); return }
        if let o = redactImage(cg, regions: regions, mode: mode, amount: amount) { preview = toNS(o) }
    }

    private var canvas: some View {
        GeometryReader { geo in
            let m = fitMetrics(geo.size, CGSize(width: W, height: H))
            let dw = W * m.s, dh = H * m.s
            let norm = { (p: CGPoint) -> CGPoint in
                CGPoint(x: min(max((p.x - m.ox) / dw, 0), 1), y: min(max((p.y - m.oy) / dh, 0), 1))
            }
            ZStack(alignment: .topLeading) {
                Image(nsImage: preview).resizable().frame(width: dw, height: dh).offset(x: m.ox, y: m.oy)
                ForEach(0..<regions.count, id: \.self) { i in
                    let r = regions[i]
                    Rectangle().stroke(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .frame(width: r.width * dw, height: r.height * dh)
                        .offset(x: m.ox + r.minX * dw, y: m.oy + r.minY * dh)
                }
                if let d = drag {
                    Rectangle().fill(Color.orange.opacity(0.25))
                        .overlay(Rectangle().stroke(Color.orange, lineWidth: 1.5))
                        .frame(width: d.width * dw, height: d.height * dh)
                        .offset(x: m.ox + d.minX * dw, y: m.oy + d.minY * dh)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in drag = rectFrom(norm(v.startLocation), norm(v.location)) }
                .onEnded { v in
                    let r = rectFrom(norm(v.startLocation), norm(v.location))
                    if r.width > 0.005 && r.height > 0.005 { regions.append(r) }
                    drag = nil
                })
        }
    }

    private func save() {
        guard !regions.isEmpty else { status = "Marca al menos una zona"; FX.done(false); return }
        guard let full = loadOrientedImage(url)?.0,
              let out = redactImage(full, regions: regions, mode: mode, amount: amount),
              let u = saveImage(out, near: url, suffix: " censurado") else {
            status = "No se pudo guardar"; FX.done(false); return
        }
        status = "Guardado: \(u.lastPathComponent)"; FX.done(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { close() }
    }
}

func openRedact(_ urls: [URL]) {
    openImageEditor(urls, title: "Censurar", size: NSSize(width: 860, height: 640), minSize: NSSize(width: 640, height: 460),
                    maxPixel: 1600) { u, cg, close in RedactView(url: u, cg: cg, close: close) }
}

// MARK: - ADD BG (fondo y marco)
enum BGKind: String, CaseIterable, Identifiable {
    case solid = "Color", gradient = "Degradado", blur = "Difuminado", clear = "Transparente"
    var id: String { rawValue }
}
enum BGRatio: String, CaseIterable, Identifiable {
    case auto = "Auto", sq = "1:1", r43 = "4:3", r169 = "16:9", p45 = "4:5", p916 = "9:16"
    var id: String { rawValue }
    var value: CGFloat? {
        switch self {
        case .auto: return nil
        case .sq: return 1
        case .r43: return 4.0 / 3
        case .r169: return 16.0 / 9
        case .p45: return 4.0 / 5
        case .p916: return 9.0 / 16
        }
    }
}

struct BGComposite: View {
    let image: NSImage
    let kind: BGKind
    let c1: Color, c2: Color
    let padding: CGFloat
    let radius: CGFloat
    let shadow: Bool
    let aspect: CGFloat

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let availW = w * (1 - 2 * padding), availH = h * (1 - 2 * padding)
            let iw = min(availW, availH * aspect), ih = iw / aspect
            ZStack {
                switch kind {
                case .solid: c1
                case .gradient: LinearGradient(colors: [c1, c2], startPoint: .topLeading, endPoint: .bottomTrailing)
                case .blur:
                    Image(nsImage: image).resizable().scaledToFill().frame(width: w, height: h)
                        .blur(radius: min(w, h) * 0.05).scaleEffect(1.25)
                case .clear: Color.clear
                }
                Image(nsImage: image).resizable().frame(width: iw, height: ih)
                    .clipShape(RoundedRectangle(cornerRadius: radius * min(iw, ih), style: .continuous))
                    .shadow(color: .black.opacity(shadow ? 0.35 : 0), radius: min(w, h) * 0.03, y: min(w, h) * 0.012)
            }
            .frame(width: w, height: h).clipped()
        }
    }
}

func bgOutSize(_ iw: CGFloat, _ ih: CGFloat, padding: CGFloat, ratio: CGFloat?) -> CGSize {
    let k = max(0.2, 1 - 2 * padding)
    var w = iw / k, h = ih / k
    if let r = ratio { w = max(iw, ih * r) / k; h = w / r }
    let m = max(w, h)
    if m > 8000 { w *= 8000 / m; h *= 8000 / m }
    return CGSize(width: w.rounded(), height: h.rounded())
}

struct BackgroundView: View {
    let url: URL
    let cg: CGImage
    let close: () -> Void
    private let nsImg: NSImage

    @State private var kind: BGKind = .gradient
    @State private var c1 = Color(red: 1.0, green: 0.62, blue: 0.20)
    @State private var c2 = Color(red: 0.98, green: 0.35, blue: 0.50)
    @State private var ratio: BGRatio = .auto
    @State private var padding: Double = 0.12
    @State private var radius: Double = 0.04
    @State private var shadow = true
    @State private var status = ""

    init(url: URL, cg: CGImage, close: @escaping () -> Void) {
        self.url = url; self.cg = cg; self.close = close
        self.nsImg = toNS(cg)
    }

    private var W: CGFloat { CGFloat(cg.width) }
    private var H: CGFloat { CGFloat(cg.height) }
    private var out: CGSize { bgOutSize(W, H, padding: CGFloat(padding), ratio: ratio.value) }

    private func composite() -> BGComposite {
        BGComposite(image: nsImg, kind: kind, c1: c1, c2: c2, padding: CGFloat(padding),
                    radius: CGFloat(radius), shadow: shadow, aspect: W / H)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $kind) { ForEach(BGKind.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 340).labelsHidden()
                if kind == .solid || kind == .gradient { ColorPicker("", selection: $c1).labelsHidden() }
                if kind == .gradient { ColorPicker("", selection: $c2).labelsHidden() }
                Spacer()
                Picker("Formato", selection: $ratio) { ForEach(BGRatio.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.menu).frame(width: 140)
            }.padding(10)
            HStack(spacing: 14) {
                Text("Margen").font(.caption); Slider(value: $padding, in: 0...0.3).frame(width: 130)
                Text("Redondeo").font(.caption); Slider(value: $radius, in: 0...0.25).frame(width: 130)
                Toggle("Sombra", isOn: $shadow)
                Spacer()
                Text("\(Int(out.width)) × \(Int(out.height)) px").font(.system(size: 12, design: .monospaced)).foregroundColor(.secondary)
            }.padding(.horizontal, 10).padding(.bottom, 10)
            Divider()
            GeometryReader { geo in
                let o = out
                let m = fitMetrics(geo.size, o)
                composite().frame(width: o.width * m.s, height: o.height * m.s)
                    .background(kind == .clear ? Color.gray.opacity(0.25) : Color.clear)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }.background(Color.black.opacity(0.85))
            Divider()
            EditorFooter(status: status, close: close, save: save)
        }
        .frame(minWidth: 680, minHeight: 500)
    }

    private func save() {
        let o = out
        guard let img = renderToCG(composite().frame(width: o.width, height: o.height)),
              let u = saveImage(img, near: url, suffix: " fondo", preferPNG: true) else {
            status = "No se pudo guardar"; FX.done(false); return
        }
        status = "Guardado: \(u.lastPathComponent)"; FX.done(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { close() }
    }
}

func openBackground(_ urls: [URL]) {
    openImageEditor(urls, title: "Fondo", size: NSSize(width: 880, height: 660), minSize: NSSize(width: 680, height: 500),
                    maxPixel: 3000) { u, cg, close in BackgroundView(url: u, cg: cg, close: close) }
}

// MARK: - FLOAT (vista previa flotante que se puede mover, redimensionar y cerrar)
struct FloatView: View {
    let image: NSImage
    let url: URL
    let close: () -> Void
    var body: some View {
        ZoomableImageView(image: image)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
            .contextMenu {
                Button("Abrir") { NSWorkspace.shared.open(url) }
                Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Copiar archivo") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([url as NSURL])
                }
                Divider()
                Button("Cerrar", action: close)
            }
    }
}

func openFloat(_ u: URL, index: Int = 0) {
    func present(_ img: NSImage) {
        NSApp.activate(ignoringOtherApps: true)
        let longest = max(img.size.width, img.size.height, 1)
        let k = 340 / longest
        let size = NSSize(width: max(img.size.width * k, 140), height: max(img.size.height * k, 140))
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: FloatView(image: img, url: u, close: { [weak p] in p?.close() }))
        p.setContentSize(size)
        p.contentAspectRatio = size
        let m = NSEvent.mouseLocation
        p.setFrameOrigin(NSPoint(x: m.x - size.width / 2 + CGFloat(index) * 28, y: m.y - size.height / 2 - CGFloat(index) * 28))
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { _ in
            openWindows.removeAll { $0 === p }
        }
        openWindows.append(p)
        p.makeKeyAndOrderFront(nil)
    }

    if isImage(u), let (cg, _) = loadOrientedImage(u, maxPixel: 1800) {
        present(toNS(cg))
    } else {
        let req = QLThumbnailGenerator.Request(fileAt: u, size: CGSize(width: 480, height: 480), scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
            DispatchQueue.main.async {
                if let c = rep?.cgImage { present(toNS(c)) }
                else { present(NSWorkspace.shared.icon(forFile: u.path)) }
            }
        }
    }
}