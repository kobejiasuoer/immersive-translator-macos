import Foundation

struct GlossaryMapping: Identifiable, Equatable {
    let id: Int
    let source: String
    let target: String
}

struct GlossaryParseResult {
    let nonEmptyLineCount: Int
    let ignoredLineCount: Int
    let ignoredLineSamples: [String]
    let duplicateSources: [String]
    let mappings: [GlossaryMapping]

    var isEmpty: Bool {
        nonEmptyLineCount == 0
    }

    var effectiveMappings: [GlossaryMapping] {
        var result: [GlossaryMapping] = []
        var indexBySource: [String: Int] = [:]

        for mapping in mappings {
            let key = mapping.source.lowercased()
            if let existingIndex = indexBySource[key] {
                result[existingIndex] = mapping
            } else {
                indexBySource[key] = result.count
                result.append(mapping)
            }
        }

        return result
    }
}

enum GlossaryImportReaderError: LocalizedError {
    case unsupportedEncoding

    var errorDescription: String? {
        switch self {
        case .unsupportedEncoding:
            return "无法识别术语表文件编码。请导出为 UTF-8、UTF-16 或纯文本后重试。"
        }
    }
}

enum GlossaryImportReader {
    static func text(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return try text(from: data)
    }

    static func text(from data: Data) throws -> String {
        for encoding in preferredEncodings(for: data) {
            guard let decoded = String(data: data, encoding: encoding) else {
                continue
            }
            let text = decoded.removingLeadingUnicodeBOM()
            guard isPlausibleText(text) else {
                continue
            }
            return text
        }

        throw GlossaryImportReaderError.unsupportedEncoding
    }

    private static func preferredEncodings(for data: Data) -> [String.Encoding] {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian]
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return [.utf16LittleEndian, .utf16, .utf8, .utf16BigEndian]
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return [.utf16BigEndian, .utf16, .utf8, .utf16LittleEndian]
        }
        if looksLikeUTF16LittleEndian(data) {
            return [.utf16LittleEndian, .utf16BigEndian, .utf8, .utf16]
        }
        if looksLikeUTF16BigEndian(data) {
            return [.utf16BigEndian, .utf16LittleEndian, .utf8, .utf16]
        }
        return [.utf8]
    }

    private static func looksLikeUTF16LittleEndian(_ data: Data) -> Bool {
        looksLikeUTF16(data, zeroByteOffset: 1)
    }

    private static func looksLikeUTF16BigEndian(_ data: Data) -> Bool {
        looksLikeUTF16(data, zeroByteOffset: 0)
    }

    private static func looksLikeUTF16(_ data: Data, zeroByteOffset: Int) -> Bool {
        guard data.count >= 6 else { return false }

        var checked = 0
        var zeroBytes = 0
        var index = zeroByteOffset
        while index < data.count {
            checked += 1
            if data[index] == 0 {
                zeroBytes += 1
            }
            index += 2
        }

        return checked > 0 && Double(zeroBytes) / Double(checked) >= 0.45
    }

    private static func isPlausibleText(_ text: String) -> Bool {
        guard !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return false
        }

        let scalars = text.unicodeScalars
        guard !scalars.isEmpty else { return true }

        let invalidControlCount = scalars.filter { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                && scalar != "\n"
                && scalar != "\r"
                && scalar != "\t"
        }.count
        return Double(invalidControlCount) / Double(scalars.count) <= 0.02
    }
}

private extension String {
    func removingLeadingUnicodeBOM() -> String {
        guard unicodeScalars.first?.value == 0xFEFF else {
            return self
        }
        return String(unicodeScalars.dropFirst())
    }
}

enum GlossaryParser {
    static let promptMappingLimit = 80

    static func parse(_ text: String) -> GlossaryParseResult {
        var mappings: [GlossaryMapping] = []
        var ignoredLineCount = 0
        var ignoredLineSamples: [String] = []
        var sourceCounts: [String: Int] = [:]
        var nonEmptyLineCount = 0

        let lines = normalizedLines(from: text)
        let allowsSemicolonColumns = shouldParseSemicolonColumns(in: lines)
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            nonEmptyLineCount += 1

            if isCommentLine(line) {
                ignoredLineCount += 1
                continue
            }

            guard let mapping = parseMapping(from: line, id: index, allowsSemicolonColumns: allowsSemicolonColumns) else {
                ignoredLineCount += 1
                if ignoredLineSamples.count < ignoredLineSampleLimit {
                    ignoredLineSamples.append(ignoredLineSample(from: line, lineNumber: index + 1))
                }
                continue
            }

            guard !isHeaderMapping(mapping) else {
                ignoredLineCount += 1
                continue
            }

            mappings.append(mapping)
            sourceCounts[mapping.source.lowercased(), default: 0] += 1
        }

        let duplicateSources = sourceCounts
            .filter { $0.value > 1 }
            .map(\.key)
            .sorted()

        return GlossaryParseResult(
            nonEmptyLineCount: nonEmptyLineCount,
            ignoredLineCount: ignoredLineCount,
            ignoredLineSamples: ignoredLineSamples,
            duplicateSources: duplicateSources,
            mappings: mappings
        )
    }

    static func promptText(from text: String, limit: Int = promptMappingLimit) -> String {
        let mappings = parse(text).effectiveMappings
        guard !mappings.isEmpty else { return "" }

        return mappings
            .prefix(limit)
            .map { "\($0.source) -> \($0.target)" }
            .joined(separator: "\n")
    }

    static func cleanedText(from text: String) -> String {
        let mappings = parse(text).effectiveMappings
        guard !mappings.isEmpty else { return "" }

        return mappings
            .map { "\($0.source) = \($0.target)" }
            .joined(separator: "\n")
    }

    private static func normalizedLines(from text: String) -> [String] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    private static func parseMapping(from line: String, id: Int, allowsSemicolonColumns: Bool) -> GlossaryMapping? {
        for delimiter in ["=>", "->", "=", "：", ":"] {
            if let mapping = parseMapping(from: line, delimiter: delimiter, id: id) {
                return mapping
            }
        }

        var columnDelimiters = ["\t", "|", ",", "，"]
        if allowsSemicolonColumns {
            columnDelimiters.append(";")
        }
        for delimiter in columnDelimiters {
            if delimiter == ";",
               let mapping = parseSemicolonMapping(from: line, id: id) {
                return mapping
            }
            if delimiter == ";" {
                continue
            }
            if let mapping = parseTwoColumnMapping(from: line, delimiter: delimiter, id: id) {
                return mapping
            }
        }

        return nil
    }

    private static func shouldParseSemicolonColumns(in lines: [String]) -> Bool {
        var candidateCount = 0

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !isCommentLine(line) else {
                continue
            }

            let columns = splitColumns(in: line, delimiter: ";").map(cleanGlossaryField)
            guard columns.count >= 2,
                  !columns[0].isEmpty,
                  !columns[1].isEmpty else {
                continue
            }

            let mapping = GlossaryMapping(id: 0, source: columns[0], target: columns[1])
            if isHeaderMapping(mapping) {
                return true
            }

            if looksLikeSemicolonGlossaryCandidate(
                source: columns[0],
                target: columns[1],
                columnCount: columns.count
            ) {
                candidateCount += 1
            }
        }

        return candidateCount >= 2
    }

    private static func looksLikeSemicolonGlossaryCandidate(
        source: String,
        target: String,
        columnCount: Int
    ) -> Bool {
        guard source.count <= 80,
              target.count <= 140,
              !looksLikeLongSentence(source),
              !looksLikeLongSentence(target) else {
            return false
        }

        if columnCount >= 3 {
            return true
        }
        return source.count <= 48 || target.count <= 80
    }

    private static func looksLikeLongSentence(_ text: String) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }

        let wordCount = clean
            .split { $0.isWhitespace || $0.isNewline }
            .count
        if wordCount >= 7 {
            return true
        }

        if clean.count >= 32,
           clean.range(of: #"[.!?。！？]"#, options: .regularExpression) != nil {
            return true
        }

        return clean.count >= 48
            && clean.range(of: #"\s"#, options: .regularExpression) != nil
    }

    private static func parseSemicolonMapping(from line: String, id: Int) -> GlossaryMapping? {
        let columns = splitColumns(in: line, delimiter: ";")
            .map(cleanGlossaryField)
        guard columns.count >= 2 else {
            return nil
        }

        let source = columns[0]
        let target = columns[1]
        guard !source.isEmpty, !target.isEmpty else {
            return nil
        }

        let mapping = GlossaryMapping(id: id, source: source, target: target)
        if isHeaderMapping(mapping) {
            return mapping
        }
        guard looksLikeSemicolonGlossaryCandidate(
            source: source,
            target: target,
            columnCount: columns.count
        ) else {
            return nil
        }
        return mapping
    }

    private static func parseMapping(from line: String, delimiter: String, id: Int) -> GlossaryMapping? {
        guard let range = line.range(of: delimiter) else { return nil }
        let source = cleanGlossaryField(String(line[..<range.lowerBound]))
        let target = cleanGlossaryField(String(line[range.upperBound...]))
        guard !source.isEmpty, !target.isEmpty else { return nil }
        return GlossaryMapping(id: id, source: source, target: target)
    }

    private static func parseTwoColumnMapping(from line: String, delimiter: String, id: Int) -> GlossaryMapping? {
        let columns = splitColumns(in: line, delimiter: delimiter)
            .map(cleanGlossaryField)
        guard columns.count >= 2 else {
            return nil
        }
        let source = columns[0]
        let target = columns[1]
        guard !source.isEmpty, !target.isEmpty else {
            return nil
        }
        return GlossaryMapping(id: id, source: source, target: target)
    }

    private static func splitColumns(in line: String, delimiter: String) -> [String] {
        guard delimiter.count == 1,
              let delimiterScalar = delimiter.unicodeScalars.first else {
            return line.components(separatedBy: delimiter)
        }

        var columns: [String] = []
        var current = String.UnicodeScalarView()
        var activeQuote: Unicode.Scalar?
        var index = line.unicodeScalars.startIndex

        while index < line.unicodeScalars.endIndex {
            let scalar = line.unicodeScalars[index]
            if let quote = activeQuote {
                if scalar == quote {
                    let nextIndex = line.unicodeScalars.index(after: index)
                    if nextIndex < line.unicodeScalars.endIndex,
                       line.unicodeScalars[nextIndex] == quote,
                       quote == "\"" {
                        current.append(scalar)
                        current.append(line.unicodeScalars[nextIndex])
                        index = line.unicodeScalars.index(after: nextIndex)
                        continue
                    }
                    current.append(scalar)
                    activeQuote = nil
                    index = nextIndex
                    continue
                }

                current.append(scalar)
                index = line.unicodeScalars.index(after: index)
                continue
            }

            if currentContainsOnlyFieldTrimCharacters(current),
               let closeQuote = matchingQuotePairs.first(where: { $0.open.unicodeScalars.first == scalar })?.close.unicodeScalars.first {
                activeQuote = closeQuote
                current.append(scalar)
                index = line.unicodeScalars.index(after: index)
                continue
            }

            if scalar == delimiterScalar {
                columns.append(String(current))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(scalar)
            }
            index = line.unicodeScalars.index(after: index)
        }

        columns.append(String(current))
        return columns
    }

    private static func currentContainsOnlyFieldTrimCharacters(_ scalars: String.UnicodeScalarView) -> Bool {
        scalars.allSatisfy { fieldTrimCharacters.contains($0) }
    }

    private static func cleanGlossaryField(_ value: String) -> String {
        var clean = value.trimmingCharacters(in: fieldTrimCharacters)
        for quotes in matchingQuotePairs {
            let openQuote = String(quotes.open)
            let closeQuote = String(quotes.close)
            guard clean.hasPrefix(openQuote), clean.hasSuffix(closeQuote), clean.count >= 2 else {
                continue
            }
            clean.removeFirst()
            clean.removeLast()
            clean = clean.trimmingCharacters(in: fieldTrimCharacters)
            if openQuote == "\"", closeQuote == "\"" {
                clean = clean.replacingOccurrences(of: "\"\"", with: "\"")
            }
            break
        }
        return clean
    }

    private static func isHeaderMapping(_ mapping: GlossaryMapping) -> Bool {
        headerSourceTokens.contains(normalizedHeaderToken(mapping.source))
            && headerTargetTokens.contains(normalizedHeaderToken(mapping.target))
    }

    private static func isCommentLine(_ line: String) -> Bool {
        line.hasPrefix("#") || line.hasPrefix("//")
    }

    private static func ignoredLineSample(from line: String, lineNumber: Int) -> String {
        let compact = line
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = compact.count > 56 ? "\(compact.prefix(56))..." : compact
        return "第 \(lineNumber) 行：\(preview)"
    }

    private static func normalizedHeaderToken(_ text: String) -> String {
        text.trimmingCharacters(in: fieldTrimCharacters)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static let fieldTrimCharacters = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\u{FEFF}"))

    private static let ignoredLineSampleLimit = 3

    private static let matchingQuotePairs: [(open: Character, close: Character)] = [
        ("\"", "\""),
        ("'", "'"),
        ("“", "”"),
        ("‘", "’"),
        ("「", "」"),
        ("『", "』")
    ]

    private static let headerSourceTokens: Set<String> = [
        "source",
        "source term",
        "term",
        "original",
        "原词",
        "源词",
        "术语"
    ]

    private static let headerTargetTokens: Set<String> = [
        "target",
        "translation",
        "translated",
        "preferred translation",
        "译法",
        "译文",
        "翻译",
        "目标译文"
    ]
}
