import AppKit
import SwiftUI

@MainActor
private final class OnboardingModel: ObservableObject {
    @Published var isAccessibilityTrusted = PermissionPrompter.isAccessibilityTrusted()
    @Published var isScreenCaptureTrusted = PermissionPrompter.isScreenCaptureTrusted()
    weak var window: NSWindow?

    func refresh() {
        isAccessibilityTrusted = PermissionPrompter.isAccessibilityTrusted()
        isScreenCaptureTrusted = PermissionPrompter.isScreenCaptureTrusted()
    }

    func close() {
        window?.close()
    }
}

final class OnboardingWindowController: NSWindowController {
    private let model = OnboardingModel()

    init(settingsStore: SettingsStore, onOpenSettings: @escaping () -> Void) {
        let view = OnboardingView(model: model, settingsStore: settingsStore, onOpenSettings: onOpenSettings)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "开始使用沉浸式翻译"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 660, height: 500))
        window.isReleasedWhenClosed = false
        model.window = window
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        model.refresh()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settingsStore: SettingsStore
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("开始使用沉浸式翻译")
                    .font(.title2.weight(.semibold))
                Text("把三个基础项处理好，热键翻译和截图 OCR 才会稳定。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                checklistRow(
                    icon: "key.fill",
                    title: apiKeyStepTitle,
                    detail: apiKeyStepDetail
                    ,
                    isDone: apiKeyStepIsDone,
                    actionTitle: "打开设置",
                    action: onOpenSettings
                )
                checklistRow(
                    icon: "keyboard",
                    title: "辅助功能权限",
                    detail: "用于在你按 Option + Space 时发送 Command + C，读取当前选中的文字。"
                    ,
                    isDone: model.isAccessibilityTrusted,
                    actionTitle: model.isAccessibilityTrusted ? "已授权" : "去授权",
                    action: {
                        PermissionPrompter.requestAccessibilityIfNeeded()
                        PermissionPrompter.openPrivacyPane(kind: .accessibility)
                        model.refresh()
                    }
                )
                checklistRow(
                    icon: "rectangle.dashed",
                    title: "屏幕录制权限",
                    detail: "用于在你框选屏幕区域后截图，再交给本机 Vision OCR 识别文字。"
                    ,
                    isDone: model.isScreenCaptureTrusted,
                    actionTitle: model.isScreenCaptureTrusted ? "已授权" : "去授权",
                    action: {
                        PermissionPrompter.requestScreenCaptureIfNeeded()
                        PermissionPrompter.openPrivacyPane(kind: .screenRecording)
                        model.refresh()
                    }
                )
            }

            Text("这个工具不会后台扫描屏幕，也不会记录键盘输入；只有触发翻译或框选 OCR 时才读取对应内容。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()

            HStack {
                Button("刷新状态") {
                    model.refresh()
                }
                Spacer()
                Button("开始使用") {
                    model.close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var apiKeyStepTitle: String {
        apiKeyIsRequired ? "配置 API Key" : "确认本地接口"
    }

    private var apiKeyStepDetail: String {
        if apiKeyIsRequired {
            return "用于调用 OpenAI 或兼容翻译接口。Key 只保存在本机 macOS Keychain。"
        }
        return "当前接口是本地 OpenAI 兼容服务，不需要真实 API Key；请确认本地模型服务已经启动。"
    }

    private var apiKeyStepIsDone: Bool {
        !apiKeyIsRequired || !settingsStore.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var apiKeyIsRequired: Bool {
        TranslationClient.requiresAPIKey(for: settingsStore.endpoint.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func checklistRow(
        icon: String,
        title: String,
        detail: String,
        isDone: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 26)
                .foregroundStyle(isDone ? .green : .blue)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.headline)
                    Label(isDone ? "已完成" : "待处理", systemImage: isDone ? "checkmark.circle.fill" : "circle")
                        .font(.caption)
                        .foregroundStyle(isDone ? .green : .secondary)
                }
                Text(detail)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(actionTitle, action: action)
                .disabled(isDone)
                .controlSize(.small)
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
