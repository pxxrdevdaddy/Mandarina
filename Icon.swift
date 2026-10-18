import AppKit

private func col(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

/// Silueta de mandarina en cristal líquido (cuerpo + hoja + rabito). `r` debe ser cuadrado.
func drawTangerine(in r: NSRect) {
    let s = r.width
    func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: r.minX + x * s, y: r.minY + y * s) }

    let body = NSBezierPath(ovalIn: NSRect(x: r.minX + 0.06 * s, y: r.minY + 0.03 * s, width: 0.88 * s, height: 0.78 * s))

    // Cuerpo: degradado translúcido
    NSGradient(colors: [col(1.0, 0.76, 0.30, 0.95), col(0.96, 0.40, 0.05, 0.88)])?.draw(in: body, angle: -65)

    NSGraphicsContext.saveGraphicsState()
    body.addClip()
    // Cáustica de luz refractada abajo
    NSGradient(colors: [col(1, 0.90, 0.50, 0.55), col(1, 0.90, 0.50, 0)])?
        .draw(fromCenter: P(0.5, 0.08), radius: 0, toCenter: P(0.5, 0.08), radius: 0.46 * s, options: [])
    // Brillo especular arriba-izquierda
    let spec = NSBezierPath(ovalIn: NSRect(x: r.minX + 0.15 * s, y: r.minY + 0.52 * s, width: 0.42 * s, height: 0.21 * s))
    NSGradient(colors: [col(1, 1, 1, 0.80), col(1, 1, 1, 0.05)])?.draw(in: spec, angle: -90)
    // Borde interior de cristal
    body.lineWidth = 0.05 * s
    col(1, 1, 1, 0.55).setStroke()
    body.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // Hoja
    let leaf = NSBezierPath()
    leaf.move(to: P(0.50, 0.78))
    leaf.curve(to: P(0.86, 0.97), controlPoint1: P(0.55, 0.93), controlPoint2: P(0.74, 1.0))
    leaf.curve(to: P(0.50, 0.78), controlPoint1: P(0.88, 0.80), controlPoint2: P(0.66, 0.74))
    leaf.close()
    NSGradient(colors: [col(0.60, 0.90, 0.48, 0.95), col(0.20, 0.64, 0.30, 0.92)])?.draw(in: leaf, angle: -45)
    leaf.lineWidth = max(0.010 * s, 0.4)
    col(1, 1, 1, 0.55).setStroke()
    leaf.stroke()

    // Rabito
    let stem = NSBezierPath(roundedRect: NSRect(x: r.minX + 0.472 * s, y: r.minY + 0.74 * s, width: 0.056 * s, height: 0.12 * s),
                            xRadius: 0.028 * s, yRadius: 0.028 * s)
    col(0.36, 0.58, 0.26, 0.95).setFill()
    stem.fill()
}

/// Icono de la app: baldosa de cristal con la mandarina.
func drawIconTile(in rect: NSRect) {
    let inset = rect.width * 0.098
    let tile = rect.insetBy(dx: inset, dy: inset)
    let rad = tile.width * 0.2237
    let path = NSBezierPath(roundedRect: tile, xRadius: rad, yRadius: rad)

    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow()
    sh.shadowColor = NSColor.black.withAlphaComponent(0.28)
    sh.shadowBlurRadius = rect.width * 0.03
    sh.shadowOffset = NSSize(width: 0, height: -rect.width * 0.012)
    sh.set()
    col(1, 1, 1).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [col(1.0, 0.985, 0.96), col(1.0, 0.87, 0.70)])?.draw(in: path, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(colors: [col(1, 1, 1, 0.85), col(1, 1, 1, 0)])?
        .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
    path.lineWidth = rect.width * 0.014
    col(1, 1, 1, 0.9).setStroke()
    path.stroke()
    NSGraphicsContext.restoreGraphicsState()

    let ts = tile.width * 0.62
    drawTangerine(in: NSRect(x: tile.midX - ts / 2, y: tile.midY - ts / 2 - tile.width * 0.02, width: ts, height: ts))
}

/// Icono de la barra de menú: solo la silueta de cristal.
func menuBarIcon() -> NSImage {
    let img = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { r in
        drawTangerine(in: r.insetBy(dx: 1, dy: 1))
        return true
    }
    img.isTemplate = false
    return img
}

/// Genera el .iconset (lo usa build.sh con `Mandarina --iconset <carpeta>`).
func writeIconset(to dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let sizes: [(String, Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]
    for (name, px) in sizes {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        drawIconTile(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: dir + "/" + name + ".png"))
        }
    }
}
