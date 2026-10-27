import AppKit
import CoreGraphics
import ImageIO
import Foundation

// 生成 App 图标：暖橙渐变底 + 白色课本 + 星星（对应 design「主色橙黄 + 辅助天蓝」）
//
// 用法（在仓库根目录执行）：
//   swift app/tools/MakeIcon.swift app/Assets.xcassets/AppIcon.appiconset/AppIcon.png
// 可选第二个参数选构图：[A] 星星压在书角外侧，[B]（默认）星星放在书页里
// 说明：输出 1024×1024 不透明 PNG；圆角由 iOS 自己切，图里不要画圆角。
let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S),
                    bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

let variant = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "B"

// 1. 背景（先铺底色，再画渐变并延伸到画布外，避免四角透出）
ctx.setFillColor(color(0xFFA52E))
ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))
let bg = CGGradient(colorsSpace: cs,
                    colors: [color(0xFFC85A), color(0xFF8A00)] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 140, y: 1024), end: CGPoint(x: 900, y: 0),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

// 2. 左上柔光
let glow = CGGradient(colorsSpace: cs,
                      colors: [color(0xFFFFFF, 0.20), color(0xFFFFFF, 0.0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 300, y: 800), startRadius: 0,
                       endCenter: CGPoint(x: 300, y: 800), endRadius: 560, options: [])

// 3. 课本：整体逆时针转 8°
ctx.saveGState()
ctx.translateBy(x: 512, y: 512)
ctx.rotate(by: -8 * .pi / 180)
ctx.scaleBy(x: 1.07, y: 1.07)

let bookW: CGFloat = 520
let bookH: CGFloat = 600
let corner: CGFloat = 84
let bookRect = CGRect(x: -bookW / 2, y: -bookH / 2, width: bookW, height: bookH)

// 落影
ctx.setFillColor(color(0xB85A00, 0.26))
let shadow = bookRect.offsetBy(dx: 8, dy: -24)
ctx.addPath(CGPath(roundedRect: shadow, cornerWidth: corner, cornerHeight: corner, transform: nil))
ctx.fillPath()

// 书封（页面）
ctx.setFillColor(color(0xFFFDF8))
ctx.addPath(CGPath(roundedRect: bookRect, cornerWidth: corner, cornerHeight: corner, transform: nil))
ctx.fillPath()

// 书脊
let spine = CGRect(x: bookRect.minX + 28, y: bookRect.minY + 28, width: 94, height: bookH - 56)
ctx.setFillColor(color(0xFFE3BF))
ctx.addPath(CGPath(roundedRect: spine, cornerWidth: 40, cornerHeight: 40, transform: nil))
ctx.fillPath()

// 页面上部两行「文字」
let textX = spine.maxX + 42
for (width, y) in [(286.0, 206.0), (286.0, 146.0)] as [(CGFloat, CGFloat)] {
    let bar = CGRect(x: textX, y: y - 16, width: width, height: 32)
    ctx.setFillColor(color(0xFFC58F))
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 16, cornerHeight: 16, transform: nil))
    ctx.fillPath()
}

// 底部书页（露出纸叠，读起来才像「书」而不是便签）
let pageBlock = CGRect(x: spine.maxX + 20, y: bookRect.minY + 40, width: bookRect.maxX - (spine.maxX + 20) - 44, height: 64)
ctx.setFillColor(color(0xFFEFD8))
ctx.addPath(CGPath(roundedRect: pageBlock, cornerWidth: 32, cornerHeight: 32, transform: nil))
ctx.fillPath()

// 4. 星星
func starPath(center: CGPoint, outer: CGFloat, inner: CGFloat, points: Int = 5) -> CGPath {
    let path = CGMutablePath()
    for i in 0..<(points * 2) {
        let radius = i.isMultiple(of: 2) ? outer : inner
        let angle = -CGFloat.pi / 2 + CGFloat(i) * .pi / CGFloat(points)
        let p = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        i == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.closeSubpath()
    return path
}

if variant == "B" {
    // 星星落在书页上（书本局部坐标系内）
    let center = CGPoint(x: 88, y: 8)
    let star = starPath(center: center, outer: 118, inner: 52)
    ctx.setFillColor(color(0xEE8C00))
    ctx.addPath(star.copy(strokingWithWidth: 0, lineCap: .round, lineJoin: .round,
                          miterLimit: 10, transform: CGAffineTransform(translationX: 0, y: -12)))
    ctx.fillPath()
    ctx.setFillColor(color(0xFFB31F))
    ctx.addPath(star)
    ctx.fillPath()
    ctx.restoreGState()
} else {
    ctx.restoreGState()
    // 星星压在书角外侧
    ctx.saveGState()
    ctx.translateBy(x: 742, y: 322)
    ctx.rotate(by: -12 * .pi / 180)
    let star = starPath(center: .zero, outer: 158, inner: 68)
    ctx.setFillColor(color(0xD97400))
    ctx.addPath(star.copy(strokingWithWidth: 0, lineCap: .round, lineJoin: .round,
                          miterLimit: 10, transform: CGAffineTransform(translationX: 0, y: -14)))
    ctx.fillPath()
    ctx.setFillColor(color(0xFFD24A))
    ctx.addPath(star)
    ctx.fillPath()
    ctx.restoreGState()
}

let image = ctx.makeImage()!
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/AppIcon.png")
let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out.path) variant=\(variant)")
