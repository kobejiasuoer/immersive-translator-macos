import AppKit
import SwiftUI

enum TranslationSource: String, Codable {
    case selection
    case screenshotOCR
    case retry
    case panel

    var displayName: String {
        switch self {
        case .selection:
            return "选中文本"
        case .screenshotOCR:
            return "截图 OCR"
        case .retry:
            return "重新翻译"
        case .panel:
            return "浮窗"
        }
    }
}

struct TranslationRecord: Identifiable, Codable, Equatable {
    let id: UUID
    var createdAt: Date
    var original: String
    var translation: String
    var targetLanguage: String
    var source: TranslationSource
    var isFavorite: Bool
}

@MainActor
final class TranslationHistoryStore: ObservableObject {
    @Published private(set) var records: [TranslationRecord] = []

    private let fileURL: URL
    private let maxRecords = 500

    init() {
        fileURL = Self.makeHistoryURL()
        records = Self.loadRecords(from: fileURL)
    }

    @discardableResult
    func add(original: String, translation: String, targetLanguage: String, source: TranslationSource) -> TranslationRecord? {
        let cleanOriginal = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTranslation = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanOriginal.isEmpty, !cleanTranslation.isEmpty else {
            return nil
        }

        if let index = records.firstIndex(where: { isSameText($0.original, cleanOriginal) && isSameText($0.translation, cleanTranslation) }) {
            var record = records.remove(at: index)
            record.createdAt = Date()
            record.targetLanguage = targetLanguage
            record.source = source
            records.insert(record, at: 0)
            save()
            return record
        }

        let record = TranslationRecord(
            id: UUID(),
            createdAt: Date(),
            original: cleanOriginal,
            translation: cleanTranslation,
            targetLanguage: targetLanguage,
            source: source,
            isFavorite: false
        )
        records.insert(record, at: 0)
        if records.count > maxRecords {
            records.removeLast(records.count - maxRecords)
        }
        save()
        return record
    }

    func isFavorite(original: String, translation: String) -> Bool {
        records.first {
            isSameText($0.original, original) && isSameText($0.translation, translation)
        }?.isFavorite ?? false
    }

    @discardableResult
    func toggleFavorite(original: String, translation: String, targetLanguage: String, source: TranslationSource) -> Bool {
        let cleanOriginal = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTranslation = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanOriginal.isEmpty, !cleanTranslation.isEmpty else {
            return false
        }

        if let index = records.firstIndex(where: { isSameText($0.original, cleanOriginal) && isSameText($0.translation, cleanTranslation) }) {
            records[index].isFavorite.toggle()
            save()
            return records[index].isFavorite
        }

        let record = TranslationRecord(
            id: UUID(),
            createdAt: Date(),
            original: cleanOriginal,
            translation: cleanTranslation,
            targetLanguage: targetLanguage,
            source: source,
            isFavorite: true
        )
        records.insert(record, at: 0)
        if records.count > maxRecords {
            records.removeLast(records.count - maxRecords)
        }
        save()
        return record.isFavorite
    }

    func toggleFavorite(recordID: UUID) {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        records[index].isFavorite.toggle()
        save()
    }

    func delete(recordID: UUID) {
        records.removeAll { $0.id == recordID }
        save()
    }

    func clearHistoryKeepingFavorites() {
        records.removeAll { !$0.isFavorite }
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(records)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("Failed to save translation history: \(error.localizedDescription)")
        }
    }

    private func isSameText(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines) == rhs.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func loadRecords(from url: URL) -> [TranslationRecord] {
        guard let data = try? Data(contentsOf: url) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([TranslationRecord].self, from: data)) ?? []
    }

    private static func makeHistoryURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return baseURL
            .appendingPathComponent("ImmersiveTranslator", isDirectory: true)
            .appendingPathComponent("translation-history.json")
    }
}

final class TranslationHistoryWindowController: NSWindowController {
    private let historyStore: TranslationHistoryStore

    init(historyStore: TranslationHistoryStore) {
        self.historyStore = historyStore
        let view = TranslationHistoryView(historyStore: historyStore)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "翻译历史"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 560))
        window.minSize = NSSize(width: 520, height: 380)
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

private enum HistoryFilter: String, CaseIterable, Identifiable {
    case all
    case favorites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "全部"
        case .favorites:
            return "收藏"
        }
    }
}

struct TranslationHistoryView: View {
    @ObservedObject var historyStore: TranslationHistoryStore
    @State private var filter: HistoryFilter = .all
    @State private var searchText = ""

    private var visibleRecords: [TranslationRecord] {
        let filtered: [TranslationRecord]
        switch filter {
        case .all:
            filtered = historyStore.records
        case .favorites:
            filtered = historyStore.records.filter(\.isFavorite)
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return filtered }
        return filtered.filter { record in
            record.original.localizedCaseInsensitiveContains(query)
                || record.translation.localizedCaseInsensitiveContains(query)
                || record.targetLanguage.localizedCaseInsensitiveContains(query)
                || record.source.displayName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("翻译历史")
                    .font(.title2.weight(.semibold))
                Spacer()
                Picker("", selection: $filter) {
                    ForEach(HistoryFilter.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索原文、译文、来源或目标语言", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("清空搜索")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            if visibleRecords.isEmpty {
                Spacer()
                Text(emptyStateText)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(visibleRecords) { record in
                    recordRow(record)
                }
                .listStyle(.inset)
            }

            HStack {
                Text("\(historyStore.records.count) 条记录")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("当前显示 \(visibleRecords.count) 条")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("清空非收藏历史") {
                    historyStore.clearHistoryKeepingFavorites()
                }
                .disabled(historyStore.records.allSatisfy(\.isFavorite))
            }
        }
        .padding(20)
    }

    private var emptyStateText: String {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "没有匹配的历史。"
        }
        return filter == .favorites ? "还没有收藏。" : "还没有翻译历史。"
    }

    private func recordRow(_ record: TranslationRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(record.source.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(record.createdAt.formatted(date: .numeric, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !record.targetLanguage.isEmpty {
                    Text(record.targetLanguage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    historyStore.toggleFavorite(recordID: record.id)
                } label: {
                    Image(systemName: record.isFavorite ? "star.fill" : "star")
                }
                .buttonStyle(.borderless)
                .help(record.isFavorite ? "取消收藏" : "收藏")

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(record.translation, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("复制译文")

                Button {
                    historyStore.delete(recordID: record.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("删除")
            }

            Text(record.translation)
                .font(.system(size: 15))
                .lineSpacing(4)
                .lineLimit(5)
                .textSelection(.enabled)

            Text(record.original)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .padding(.vertical, 8)
    }
}
