import SwiftUI

/// 麦克风说明页（tasks 4.8）：先讲清楚"录音只留在 iPad 上"，再弹系统授权。
/// 系统授权只能弹一次，所以这一步放在跟读面板第一次点麦克风之前。
struct MicPermissionPrimer: View {
    var onAllow: () -> Void
    var onLater: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("🎤").font(.system(size: 46))

            Text("跟读要用到麦克风")
                .font(.system(size: 21, weight: .heavy))
                .foregroundStyle(Theme.ink)

            VStack(alignment: .leading, spacing: 8) {
                bullet("录音只存在这台 iPad 上，不会上传，也不发给任何人")
                bullet("读完立刻用来判分，换一个词就删掉")
                bullet("不想开也能学：只看不听、点「先跳过」")
            }
            .padding(.horizontal, 6)
            .padding(.top, 2)

            Spacer(minLength: 6)

            Button(action: onAllow) {
                KidButtonLabel(title: "好的，开始录音")
            }
            .buttonStyle(KidButtonStyle())

            Button(action: onLater) {
                Text("以后再说")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 26)
        .padding(.top, 26)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("·").font(.system(size: 15, weight: .heavy)).foregroundStyle(Theme.orange)
            Text(text)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
