import SwiftUI

/// A7 空状态：没有已安装学期时的「学习」Tab。
struct EmptyContentView: View {
    var onRetry: (() -> Void)?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 88, weight: .light))
                .foregroundStyle(Color(hex: 0xE8DED2))

            Text("还没有学习内容")
                .font(.system(size: 34, weight: .heavy))
                .foregroundStyle(Theme.ink)

            Text("请在家里电脑上启动内容服务，并确认 iPad 连在同一个 Wi-Fi\n下载入口：家长模式（右上角小锁）→ 内容管理")
                .font(.system(size: 18))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(7)

            if let onRetry {
                Button(action: onRetry) {
                    KidButtonLabel(title: "重试", style: .blue)
                        .frame(width: 200)
                }
                .buttonStyle(KidButtonStyle())
                .padding(.top, 4)
            }

            Text("已安装的学期不受影响，可正常离线学习")
                .font(.system(size: 14))
                .foregroundStyle(Theme.faint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 90)
    }
}

/// A8 的一部分：内容解码失败 / 资产缺失的兜底页（不崩、给出下一步）。
struct ContentProblemView: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 52))
                .foregroundStyle(Theme.orange)
            Text("内容暂时打不开")
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(Theme.ink)
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
            if let retry {
                Button(action: retry) {
                    KidButtonLabel(title: "再试一次", style: .ghost, compact: true)
                        .frame(width: 180)
                }
                .buttonStyle(KidButtonStyle())
                .padding(.top, 2)
            }
            Text("仍不行就让家长进「内容管理」重新下载该学期。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.faint)
        }
        .padding(28)
    }
}
