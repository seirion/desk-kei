// 앱 아이콘(1024x1024 PNG)을 그린다.  사용법: swift Scripts/make-icon.swift <출력.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// macOS 아이콘 규격: 1024 캔버스 안에 824 크기의 둥근 사각형
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.shadowBlurRadius = 28
shadow.set()
color(0x0F1B33).setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(colors: [color(0x22385F), color(0x0B1426)])!.draw(in: shape, angle: -90)

shape.addClip()

// 은은한 가로 격자
color(0xFFFFFF, 0.06).setStroke()
for i in 1...4 {
    let y = body.minY + body.height * CGFloat(i) / 5
    let line = NSBezierPath()
    line.move(to: NSPoint(x: body.minX + 70, y: y))
    line.line(to: NSPoint(x: body.maxX - 70, y: y))
    line.lineWidth = 4
    line.stroke()
}

// 캔들: (중심 x, 몸통 아래, 몸통 위, 꼬리 아래, 꼬리 위, 상승 여부)
let up = color(0xF0524F), down = color(0x3D8BFD)
let candles: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, Bool)] = [
    (284, 330, 470, 280, 520, false),
    (420, 380, 560, 340, 610, true),
    (556, 470, 620, 420, 690, false),
    (692, 520, 760, 470, 820, true),
]
let bodyW: CGFloat = 76
for (x, lo, hi, wickLo, wickHi, isUp) in candles {
    let tint = isUp ? up : down
    tint.setFill()
    NSBezierPath(roundedRect: NSRect(x: x - 6, y: wickLo, width: 12, height: wickHi - wickLo), xRadius: 6, yRadius: 6).fill()
    NSBezierPath(roundedRect: NSRect(x: x - bodyW / 2, y: lo, width: bodyW, height: hi - lo), xRadius: 16, yRadius: 16).fill()
}

// 상승 추세선
let trend = NSBezierPath()
trend.move(to: NSPoint(x: 210, y: 300))
trend.curve(to: NSPoint(x: 800, y: 790), controlPoint1: NSPoint(x: 420, y: 330), controlPoint2: NSPoint(x: 600, y: 640))
trend.lineWidth = 16
trend.lineCapStyle = .round
color(0xFFFFFF, 0.9).setStroke()
trend.stroke()

NSGraphicsContext.restoreGraphicsState()

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
