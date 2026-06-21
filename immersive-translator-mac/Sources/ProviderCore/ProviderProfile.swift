import Foundation

public struct ProviderProfile: Identifiable, Codable, Equatable {
    public let id: String
    public var displayName: String
    public var endpoint: String
    public var model: String
    public var isBuiltin: Bool
    public var customModels: [String]

    public init(id: String, displayName: String, endpoint: String, model: String, isBuiltin: Bool, customModels: [String]) {
        self.id = id
        self.displayName = displayName
        self.endpoint = endpoint
        self.model = model
        self.isBuiltin = isBuiltin
        self.customModels = customModels
    }

    // 硬编码厂商官方模型,不进 UserDefaults
    public static let builtinModelCandidates: [String: [String]] = [
        "deepseek": ["deepseek-v4-flash", "deepseek-v4", "deepseek-reasoner"],
        "zhipu":    ["glm-5.2", "glm-5.2-air", "glm-4-flash"],
        "openai":   ["gpt-5.4-mini", "gpt-5.4", "gpt-4o-mini"],
        // 自定义 provider 无内置候选,customModels 是唯一来源
    ]

    public static let builtinPresets: [ProviderProfile] = [
        ProviderProfile(
            id: "deepseek", displayName: "DeepSeek",
            endpoint: "https://api.deepseek.com/chat/completions",
            model: "deepseek-v4-flash",
            isBuiltin: true, customModels: []
        ),
        ProviderProfile(
            id: "zhipu", displayName: "智谱",
            endpoint: "https://open.bigmodel.cn/api/paas/v4/chat/completions",
            model: "glm-5.2",
            isBuiltin: true, customModels: []
        ),
        ProviderProfile(
            id: "openai", displayName: "OpenAI",
            endpoint: "https://api.openai.com/v1/chat/completions",
            model: "gpt-5.4-mini",
            isBuiltin: true, customModels: []
        ),
    ]

    // UI 下拉展示用 = 内置候选 + 自定义历史(去重,内置在前,保持插入顺序)
    public var modelCandidates: [String] {
        let builtin = Self.builtinModelCandidates[id] ?? []
        var seen = Set<String>()
        var result: [String] = []
        for m in builtin + customModels {
            let trimmed = m.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    // 用户自由填了模型名 → 追加到 customModels(去重:对比内置 + 已有;超 8 条淘汰最旧)
    public mutating func appendCustomModel(_ model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let builtin = Self.builtinModelCandidates[id] ?? []
        guard !builtin.contains(trimmed), !customModels.contains(trimmed) else { return }
        customModels.append(trimmed)
        if customModels.count > 8 {
            customModels.removeFirst()
        }
    }
}
