import SwiftData
import SwiftUI
import UIKit

/// 家长验证闸门（tasks 6.1）：PIN 键盘 + 四层恢复。
/// 进来先选「我是妈妈 / 爸爸」（只用于审计，不做额外验证），再输 4 位 PIN。
struct ParentGateView: View {
    /// 解锁后回调，带上家长名字（审计用）
    var onUnlocked: (String) -> Void
    var onCancel: () -> Void

    @State private var parentName = "妈妈"
    @State private var pin = ""
    @State private var errorText: String?
    @State private var showRecovery = false
    @State private var showSetPin = false
    @State private var newRecoveryCode: String?

    var body: some View {
        VStack(spacing: 16) {
            header

            if ParentAuth.hasPin {
                pinPad
            } else {
                setupPrompt
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
        .sheet(isPresented: $showRecovery) {
            ParentRecoveryView { recovered in
                showRecovery = false
                if recovered {
                    auditAndUnlock(method: "recovery")
                }
            } onCancel: {
                showRecovery = false
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showSetPin) {
            ParentSetPinView { pin, code in
                newRecoveryCode = code
                showSetPin = false
                ParentAuth.audit("pin_created")
                pin = ""
            } onCancel: {
                showSetPin = false
            }
            .presentationDetents([.large])
        }
        .sheet(item: Binding(get: { newRecoveryCode.map { RecoveryCodeBox(code: $0) } },
                             set: { if $0 == nil { newRecoveryCode = nil } })) { box in
            RecoveryCodeView(code: box.code) {
                newRecoveryCode = nil
                auditAndUnlock(method: "pin_created")
            }
            .presentationDetents([.height(420)])
        }
    }

    private struct RecoveryCodeBox: Identifiable {
        let code: String
        var id: String { code }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Button {
                    onCancel()
                } label: {
                    Text("取消")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
                Spacer()
            }

            Text("🔒").font(.system(size: 40))
            Text("家长模式")
                .font(.system(size: 24, weight: .heavy))
                .foregroundStyle(Theme.ink)

            Picker("我是", selection: $parentName) {
                Text("妈妈").tag("妈妈")
                Text("爸爸").tag("爸爸")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)
        }
    }

    // MARK: - 输入 PIN

    private var pinPad: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .fill(index < pin.count ? Theme.orange : Theme.track)
                        .frame(width: 16, height: 16)
                }
            }
            .padding(.top, 4)

            if let errorText {
                Text(errorText)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.red)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(84), spacing: 14), count: 3), spacing: 12) {
                ForEach(1...9, id: \.self) { number in
                    digitButton("\(number)")
                }
                Button {
                    pin = ""
                    errorText = nil
                } label: {
                    Text("清空")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 84, height: 58)
                }
                .buttonStyle(.plain)
                digitButton("0")
                Button {
                    if !pin.isEmpty { pin.removeLast() }
                } label: {
                    Image(systemName: "delete.left")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 84, height: 58)
                        .background(Theme.chipBg)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: 300)

            Button {
                showRecovery = true
            } label: {
                Text("忘记 PIN？")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.blueInk)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
    }

    private func digitButton(_ digit: String) -> some View {
        Button {
            guard pin.count < 4 else { return }
            pin.append(digit)
            errorText = nil
            if pin.count == 4 { submit(pin) }
        } label: {
            Text(digit)
                .font(.system(size: 24, weight: .heavy))
                .foregroundStyle(Theme.ink)
                .frame(width: 84, height: 58)
                .background(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Theme.line, lineWidth: 1.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 首次设置

    private var setupPrompt: some View {
        VStack(spacing: 12) {
            Text("还没有设置家长 PIN")
                .font(.system(size: 17, weight: .heavy))
                .foregroundStyle(Theme.ink)
            Text("设一个 4 位数字，只有家长知道；忘记时可以用设备密码或恢复码找回")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
            Button {
                showSetPin = true
            } label: {
                KidButtonLabel(title: "设置家长 PIN")
            }
            .buttonStyle(KidButtonStyle())
            .padding(.top, 4)
        }
        .padding(24)
        .kidCard()
        .frame(maxWidth: 520)
    }

    // MARK: - 动作

    private func submit(_ value: String) {
        if ParentAuth.verify(pin: value) {
            auditAndUnlock(method: "pin")
        } else {
            errorText = "PIN 不对，再试一次"
            pin = ""
        }
    }

    private func auditAndUnlock(method: String) {
        ParentAuth.audit("enter_parent_mode", detail: "\(parentName)/\(method)")
        onUnlocked(parentName)
    }
}

// MARK: - 设置 PIN

/// 设置 PIN → 展示一次性恢复码
struct ParentSetPinView: View {
    var onDone: (String, String) -> Void
    var onCancel: () -> Void

    @State private var first = ""
    @State private var second = ""
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("设置 4 位家长 PIN")
                .font(.system(size: 21, weight: .heavy))
                .foregroundStyle(Theme.ink)

            SecureField("输入 4 位数字", text: $first)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.system(size: 24, weight: .heavy))
                .multilineTextAlignment(.center)
                .padding()
                .background(Theme.chipBg)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(maxWidth: 260)

            SecureField("再输一次", text: $second)
                .keyboardType(.numberPad)
                .font(.system(size: 24, weight: .heavy))
                .multilineTextAlignment(.center)
                .padding()
                .background(Theme.chipBg)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(maxWidth: 260)

            if let errorText {
                Text(errorText).font(.system(size: 13)).foregroundStyle(Theme.red)
            }

            HStack(spacing: 12) {
                Button("取消", action: onCancel)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.muted)

                Button {
                    save()
                } label: {
                    KidButtonLabel(title: "保存", compact: true)
                }
                .buttonStyle(KidButtonStyle())
            }
            .padding(.top, 6)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    private func save() {
        guard first.count == 4, first.allSatisfy(\.isNumber) else {
            errorText = "要 4 位数字"
            return
        }
        guard first == second else {
            errorText = "两次输入不一样"
            return
        }
        guard let code = ParentAuth.setPin(first) else {
            errorText = "保存失败，再试一次"
            return
        }
        onDone(first, code)
    }
}

// MARK: - 展示恢复码（一次性）

struct RecoveryCodeView: View {
    let code: String
    var onDone: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(spacing: 14) {
            Text("🔑").font(.system(size: 42))
            Text("这是你的恢复码")
                .font(.system(size: 21, weight: .heavy))
                .foregroundStyle(Theme.ink)
            Text("忘记 PIN 时用它进来。它只显示这一次，请拍照或抄下来。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)

            Text(code)
                .font(.system(size: 34, weight: .heavy, design: .monospaced))
                .tracking(8)
                .foregroundStyle(Theme.orangeDark)
                .padding(.vertical, 14)
                .padding(.horizontal, 22)
                .background(Theme.orangeSoft)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Button {
                UIPasteboard.general.string = code
                copied = true
            } label: {
                Text(copied ? "已复制" : "复制恢复码")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.blueInk)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)

            Button(action: onDone) {
                KidButtonLabel(title: "我记下了")
            }
            .buttonStyle(KidButtonStyle())
            .padding(.horizontal, 24)
        }
        .padding(.top, 22)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}

// MARK: - 四层恢复

struct ParentRecoveryView: View {
    var onFinished: (Bool) -> Void
    var onCancel: () -> Void

    @State private var code = ""
    @State private var message: String?
    @State private var working = false
    @State private var newCode: String?

    var body: some View {
        NavigationStack {
            List {
                Section("第 1 层 · 设备密码 / Face ID") {
                    Button {
                        Task { await useDeviceOwner() }
                    } label: {
                        Label("用设备密码或 Face ID 确认", systemImage: "faceid")
                    }
                    .disabled(working)
                }

                Section("第 2 层 · 恢复码") {
                    TextField("6 位恢复码", text: $code)
                        .keyboardType(.numberPad)
                        .font(.system(size: 20, weight: .heavy, design: .monospaced))
                    Button("用恢复码进入") {
                        if ParentAuth.verifyRecoveryCode(code) {
                            ParentAuth.audit("recovery_code_used")
                            onFinished(true)
                        } else {
                            message = "恢复码不对"
                        }
                    }
                    .disabled(code.count != 6)
                }

                if let message {
                    Section { Text(message).foregroundStyle(Theme.red) }
                }

                Section {
                    Text("如果恢复码也忘了：先用设备密码进来，再重新生成一个新的恢复码。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.muted)
                    Button("重新生成恢复码（需先用设备密码确认）") {
                        Task { await regenerate() }
                    }
                    .disabled(working)
                } header: {
                    Text("第 3 层 · 重新生成恢复码")
                }

                Section {
                    Button(role: .destructive) {
                        ParentAuth.resetCredentials()
                        onFinished(false)
                    } label: {
                        Label("Debug 重置（保留学习记录）", systemImage: "wrench.and.screwdriver")
                    }
                    Text("只清掉家长 PIN 与恢复码，孩子的学习进度、星星、徽章都保留。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.muted)
                } header: {
                    Text("第 4 层 · 重置凭据")
                }
            }
            .navigationTitle("找回家长 PIN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消", action: onCancel)
                }
            }
            .sheet(item: Binding(get: { newCode.map { CodeBox(code: $0) } },
                                 set: { if $0 == nil { newCode = nil } })) { box in
                RecoveryCodeView(code: box.code) { newCode = nil }
                    .presentationDetents([.height(420)])
            }
        }
    }

    private struct CodeBox: Identifiable {
        let code: String
        var id: String { code }
    }

    private func useDeviceOwner() async {
        working = true
        let ok = await ParentAuth.confirmWithDeviceOwner(reason: "确认是家长本人后进入家长模式")
        working = false
        if ok {
            ParentAuth.audit("device_owner_unlock")
            onFinished(true)
        } else {
            message = "设备密码验证没通过"
        }
    }

    private func regenerate() async {
        working = true
        let ok = await ParentAuth.confirmWithDeviceOwner(reason: "确认身份后重新生成恢复码")
        working = false
        guard ok else {
            message = "需要先用设备密码确认身份"
            return
        }
        newCode = ParentAuth.regenerateRecoveryCode()
        ParentAuth.audit("recovery_code_regenerated")
    }
}
