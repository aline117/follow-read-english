import SwiftUI

/// 原型（`openspec/.../prototype/proto-*.html`）里的视觉常量，一处定义、各处引用。
/// 取色与圆角都直接照抄原型 CSS 的 `:root` 变量。
enum Theme {
    static let orange = Color(hex: 0xFF9F1C)
    static let orangeDark = Color(hex: 0xF08A00)
    static let orangeSoft = Color(hex: 0xFFF1DE)
    static let orangeLine = Color(hex: 0xFFD9A6)

    static let blue = Color(hex: 0x4CC9F0)
    static let blueSoft = Color(hex: 0xE6F7FD)
    static let blueInk = Color(hex: 0x3AA6C9)

    static let green = Color(hex: 0x57CC99)
    static let greenSoft = Color(hex: 0xE6F8F0)
    static let greenInk = Color(hex: 0x2E9E6B)

    static let red = Color(hex: 0xEF6F6C)
    static let redSoft = Color(hex: 0xFDE8E7)

    static let ink = Color(hex: 0x3A2E2A)
    static let muted = Color(hex: 0x9A8C86)
    static let faint = Color(hex: 0xB9ABA2)

    static let bg = Color(hex: 0xFFF9F2)
    static let line = Color(hex: 0xF1E5D8)
    static let track = Color(hex: 0xF0E6DA)
    static let cardLocked = Color(hex: 0xFBF6F0)
    static let chipBg = Color(hex: 0xF6F0E8)

    static let radius: CGFloat = 22
    static let cardPadding: CGFloat = 20
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

// MARK: - 卡片

/// 原型 `.task` / `.unit`：白底 + 2px 描边 + 大圆角 + 很淡的投影。
struct KidCard: ViewModifier {
    var background: Color = .white
    var border: Color = Theme.line
    var padding: CGFloat = Theme.cardPadding

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(border, lineWidth: 2)
            )
            .shadow(color: Color(hex: 0x966E46).opacity(0.07), radius: 11, x: 0, y: 5)
    }
}

extension View {
    func kidCard(background: Color = .white,
                 border: Color = Theme.line,
                 padding: CGFloat = Theme.cardPadding) -> some View {
        modifier(KidCard(background: background, border: border, padding: padding))
    }
}

// MARK: - 进度条

/// 原型 `.bar`：粗圆角轨道；橙色（首页）或绿色（单元进度）渐变。
struct KidProgressBar: View {
    enum Tint {
        case orange
        case green

        var colors: [Color] {
            switch self {
            case .orange: return [Color(hex: 0xFFC46B), Theme.orange]
            case .green: return [Color(hex: 0x8FE3C0), Theme.green]
            }
        }
    }

    var value: Double
    var tint: Tint = .orange
    var height: CGFloat = 15

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(LinearGradient(colors: tint.colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, min(1, value)) * geometry.size.width)
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.4), value: value)
    }
}

// MARK: - 按钮

/// 原型 `.btn`：58 高、18 圆角、主色填充 + 硬投影（`0 7px 0` 那种“厚”按钮）。
struct KidButtonLabel: View {
    enum Style {
        case primary
        case ghost
        case blue
    }

    let title: String
    var systemImage: String?
    var style: Style = .primary
    var compact = false

    var body: some View {
        HStack(spacing: 9) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: compact ? 15 : 18, weight: .bold))
            }
            Text(title).font(.system(size: compact ? 15 : (style == .primary ? 21 : 17), weight: .bold))
        }
        .foregroundStyle(style == .ghost ? Theme.ink : .white)
        .frame(maxWidth: .infinity)
        .frame(height: compact ? 44 : 58)
        .background(
            RoundedRectangle(cornerRadius: compact ? 13 : 18, style: .continuous)
                .fill(style == .ghost ? Color.white : (style == .blue ? Theme.blue : Theme.orange))
        )
        .overlay(
            RoundedRectangle(cornerRadius: compact ? 13 : 18, style: .continuous)
                .strokeBorder(style == .ghost ? Theme.line : .clear, lineWidth: 2)
        )
        .shadow(color: style == .ghost ? Color(hex: 0xEAE0D4)
                : (style == .blue ? Color(hex: 0x35A9CE) : Theme.orangeDark),
                radius: 0, x: 0, y: compact ? 4 : 7)
    }
}

/// 把 `KidButtonLabel` 用在 `NavigationLink` / `Button` 上时压掉系统的高亮与内边距。
struct KidButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.85 : 1)
            .offset(y: configuration.isPressed ? 3 : 0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

// MARK: - 小部件

/// 首页右上角那颗「★ 0」。
struct StarPill: View {
    let stars: Int

    var body: some View {
        HStack(spacing: 5) {
            Text("★").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.orangeDark)
            Text("\(stars)").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(Theme.orangeSoft)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Theme.orangeLine, lineWidth: 2))
    }
}

/// 首页统计格（`.stat`）。
struct StatTile: View {
    let icon: String
    let iconColor: Color
    let value: String
    let label: String
    var background: Color = Theme.orangeSoft

    var body: some View {
        HStack(spacing: 11) {
            Text(icon)
                .font(.system(size: 17, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(iconColor)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.system(size: 21, weight: .heavy)).foregroundStyle(Theme.ink)
                Text(label).font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

/// B1 的单元序号方块（`.unit .no`）。
struct UnitBadge: View {
    let number: Int
    var locked = false
    var done = false

    var body: some View {
        Text("\(number)")
            .font(.system(size: 20, weight: .heavy))
            .foregroundStyle(foreground)
            .frame(width: 50, height: 50)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private var background: Color {
        if done { return Theme.greenSoft }
        return locked ? Color(hex: 0xEFE7DD) : Theme.orangeSoft
    }

    private var foreground: Color {
        if done { return Theme.greenInk }
        return locked ? Theme.faint : Theme.orangeDark
    }
}
