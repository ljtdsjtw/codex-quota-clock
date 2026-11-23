import SwiftUI

struct ProtectionPanel: View {
    @ObservedObject var model: Model
    @State private var draft: GuardSettings
    @Environment(\.dismiss) private var dismiss

    init(model: Model, settings: GuardSettings) {
        self.model = model
        _draft = State(initialValue: settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("保护与刷新").font(.title2.bold())
                Spacer()
                Text(model.protectionStatus).font(.callout).foregroundStyle(.secondary)
            }
            Toggle("周额度不足时自动断开本机 Codex 对话", isOn: $draft.enabled)
                .toggleStyle(.switch)
            HStack {
                Text("剩余额度低于")
                Spacer()
                Stepper("\(draft.threshold)%", value: $draft.threshold, in: 1...100)
                    .monospacedDigit().fixedSize().accessibilityLabel("断开阈值，\(draft.threshold)%")
            }
            Text("恰好剩 \(draft.threshold)% 时继续。启用后，首次读到低于阈值时会断开当时的本地对话。每周只触发一次，之后可以手动重开。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Text("额度检查间隔")
                Spacer()
                Picker("额度检查间隔", selection: $draft.interval) {
                    ForEach(GuardSettings.intervals, id: \.self) { seconds in
                        Text(refreshIntervalText(seconds)).tag(seconds)
                    }
                }.labelsHidden().frame(width: 110)
            }
            Text("面板和保护共用一次额度读取，小组件随系统刷新。启用保护后，退出面板或重新登录 Mac，后台仍会检查。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let issue = model.settingsProblem {
                Text(issue).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(model.applying ? "保存中…" : "保存") {
                    model.apply(draft) { saved in if saved { dismiss() } }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 400).disabled(model.applying)
        .interactiveDismissDisabled(model.applying)
    }
}
