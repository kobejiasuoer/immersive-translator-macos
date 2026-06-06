import AppKit
import SwiftUI

final class SettingsStore: ObservableObject {
    @Published var apiKey: String {
        didSet {
            do {
                try KeychainStore.setString(apiKey, service: Keys.keychainService, account: Keys.apiKey)
                UserDefaults.standard.removeObject(forKey: Keys.apiKey)
                apiKeyStorageError = nil
            } catch {
                apiKeyStorageError = error.localizedDescription
            }
        }
    }

    @Published var apiKeyStorageError: String?

    @Published var endpoint: String {
        didSet { UserDefaults.standard.set(endpoint, forKey: Keys.endpoint) }
    }

    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: Keys.model) }
    }

    @Published var targetLanguage: String {
        didSet { UserDefaults.standard.set(targetLanguage, forKey: Keys.targetLanguage) }
    }

    init() {
        let apiKeyResult = Self.loadAPIKey()
        apiKey = apiKeyResult.value
        apiKeyStorageError = apiKeyResult.errorMessage
        endpoint = UserDefaults.standard.string(forKey: Keys.endpoint) ?? "https://api.openai.com/v1/chat/completions"
        model = UserDefaults.standard.string(forKey: Keys.model) ?? "gpt-4o-mini"
        targetLanguage = UserDefaults.standard.string(forKey: Keys.targetLanguage) ?? "简体中文"
    }

    private static func loadAPIKey() -> (value: String, errorMessage: String?) {
        let legacyKey = UserDefaults.standard.string(forKey: Keys.apiKey) ?? ""

        do {
            if let keychainKey = try KeychainStore.string(service: Keys.keychainService, account: Keys.apiKey),
               !keychainKey.isEmpty {
                UserDefaults.standard.removeObject(forKey: Keys.apiKey)
                UserDefaults.standard.synchronize()
                return (keychainKey, nil)
            }

            if !legacyKey.isEmpty {
                try KeychainStore.setString(legacyKey, service: Keys.keychainService, account: Keys.apiKey)
                UserDefaults.standard.removeObject(forKey: Keys.apiKey)
                UserDefaults.standard.synchronize()
                return (legacyKey, nil)
            }
            UserDefaults.standard.removeObject(forKey: Keys.apiKey)
            UserDefaults.standard.synchronize()
            return ("", nil)
        } catch {
            if legacyKey.isEmpty {
                UserDefaults.standard.removeObject(forKey: Keys.apiKey)
                UserDefaults.standard.synchronize()
            }
            return (legacyKey, error.localizedDescription)
        }
    }

    private enum Keys {
        static let apiKey = "apiKey"
        static let keychainService = "local.immersive-translator.mvp"
        static let endpoint = "endpoint"
        static let model = "model"
        static let targetLanguage = "targetLanguage"
    }
}

final class SettingsWindowController: NSWindowController {
    private let settingsStore: SettingsStore

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        let view = SettingsView(settingsStore: settingsStore)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "沉浸式翻译设置"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 370))
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    @ObservedObject var settingsStore: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("沉浸式翻译设置")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text(currentProviderHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                labeledField("API Key", text: $settingsStore.apiKey, secure: true)
                labeledField("接口地址", text: $settingsStore.endpoint)
                labeledField("模型", text: $settingsStore.model)
                labeledField("目标语言", text: $settingsStore.targetLanguage)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("常用配置")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    presetButton("DeepSeek 快速", endpoint: "https://api.deepseek.com/chat/completions", model: "deepseek-chat")
                    presetButton("DeepSeek V4 Flash", endpoint: "https://api.deepseek.com/chat/completions", model: "deepseek-v4-flash")
                    presetButton("OpenAI Mini", endpoint: "https://api.openai.com/v1/chat/completions", model: "gpt-4o-mini")
                }
            }

            if let apiKeyStorageError = settingsStore.apiKeyStorageError {
                Text("API Key 未能写入 Keychain：\(apiKeyStorageError)")
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else {
                Text("API Key 会保存到 macOS Keychain，其它设置保存在本机。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("打开辅助功能设置") {
                    PermissionPrompter.openPrivacyPane(kind: .accessibility)
                }
                Button("打开屏幕录制设置") {
                    PermissionPrompter.openPrivacyPane(kind: .screenRecording)
                }
                Spacer()
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func labeledField(_ title: String, text: Binding<String>, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            if secure {
                SecureField(title, text: text)
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField(title, text: text)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var currentProviderHint: String {
        let endpoint = settingsStore.endpoint.lowercased()
        if endpoint.contains("deepseek") {
            return "DeepSeek 兼容接口"
        }
        if endpoint.contains("bigmodel") || endpoint.contains("z.ai") {
            return "智谱 GLM 兼容接口"
        }
        if endpoint.contains("openai") {
            return "OpenAI 接口"
        }
        return "OpenAI Chat Completions 兼容接口"
    }

    private func presetButton(_ title: String, endpoint: String, model: String) -> some View {
        Button(title) {
            settingsStore.endpoint = endpoint
            settingsStore.model = model
        }
        .controlSize(.small)
        .help("填入 \(model) 的接口和模型名，不会改动 API Key")
    }
}
