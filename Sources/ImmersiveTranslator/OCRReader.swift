import CoreGraphics
import Foundation
import Vision

enum OCRError: LocalizedError {
    case recognitionFailed

    var errorDescription: String? {
        switch self {
        case .recognitionFailed:
            return "OCR 识别失败。"
        }
    }
}

enum OCRReader {
    static func recognizeText(
        in image: CGImage,
        mode: OCRRecognitionMode = .accurate,
        languagePreset: OCRLanguagePreset = .autoMixed
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let preparedImage = prepareImageForRecognition(image)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = mode == .accurate ? .accurate : .fast
            request.usesLanguageCorrection = mode == .accurate
            request.recognitionLanguages = languagePreset.recognitionLanguages
            request.minimumTextHeight = minimumTextHeight(for: preparedImage)

            let handler = VNImageRequestHandler(cgImage: preparedImage)
            try handler.perform([request])

            guard let observations = request.results, !observations.isEmpty else {
                return ""
            }

            let lines = observations
                .compactMap { observation -> OCRLine? in
                    guard let text = observation.topCandidates(1).first?.string else { return nil }
                    let cleaned = cleanup(text)
                    guard !cleaned.isEmpty else { return nil }
                    return OCRLine(rect: observation.boundingBox, text: cleaned)
                }

            return mergeLines(lines)
        }.value
    }
}

private struct OCRLine {
    let rect: CGRect
    let text: String
}

private struct OCRRow {
    let index: Int
    var lines: [OCRLine]
}

private struct OCRSegment {
    let rowIndex: Int
    var rect: CGRect
    var text: String
}

private struct OCRBlock {
    var segments: [OCRSegment]
    var rect: CGRect
    var averageLineHeight: CGFloat

    init(segment: OCRSegment) {
        segments = [segment]
        rect = segment.rect
        averageLineHeight = segment.rect.height
    }

    mutating func add(_ segment: OCRSegment) {
        segments.append(segment)
        rect = rect.union(segment.rect)
        averageLineHeight = segments.map { $0.rect.height }.average
    }
}

private enum OCRBoundary {
    case join
    case line
    case paragraph
}

private func prepareImageForRecognition(_ image: CGImage) -> CGImage {
    let width = image.width
    let height = image.height
    let maxSide = max(width, height)
    let minUsefulSide = 1400

    guard maxSide < minUsefulSide else {
        return image
    }

    let scale = min(3.0, CGFloat(minUsefulSide) / CGFloat(maxSide))
    let targetWidth = Int((CGFloat(width) * scale).rounded())
    let targetHeight = Int((CGFloat(height) * scale).rounded())
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

    guard let context = CGContext(
        data: nil,
        width: targetWidth,
        height: targetHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        return image
    }

    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
    return context.makeImage() ?? image
}

private func minimumTextHeight(for image: CGImage) -> Float {
    let shortSide = min(image.width, image.height)
    if shortSide < 600 {
        return 0.006
    }
    if shortSide < 1200 {
        return 0.004
    }
    return 0.0025
}

private func cleanup(_ text: String) -> String {
    text
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func mergeLines(_ lines: [OCRLine]) -> String {
    guard !lines.isEmpty else { return "" }

    let rows = makeRows(from: lines)
    let segments = makeSegments(from: rows)
    let blocks = makeBlocks(from: segments)

    return blocks
        .sorted(by: blockReadingOrder)
        .map(renderBlock)
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
        .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
}

private func makeRows(from lines: [OCRLine]) -> [OCRRow] {
    let sorted = lines.sorted { left, right in
        let yDelta = abs(left.rect.midY - right.rect.midY)
        if yDelta > max(0.012, min(left.rect.height, right.rect.height) * 0.55) {
            return left.rect.midY > right.rect.midY
        }
        return left.rect.minX < right.rect.minX
    }

    var rows: [[OCRLine]] = []
    for line in sorted {
        if let lastRow = rows.indices.last,
           let anchor = rows[lastRow].first,
           abs(anchor.rect.midY - line.rect.midY) <= max(0.014, max(anchor.rect.height, line.rect.height) * 0.7) {
            rows[lastRow].append(line)
        } else {
            rows.append([line])
        }
    }

    return rows
        .enumerated()
        .map { index, row in
            OCRRow(index: index, lines: row.sorted { $0.rect.minX < $1.rect.minX })
        }
}

private func makeSegments(from rows: [OCRRow]) -> [OCRSegment] {
    rows.flatMap { row -> [OCRSegment] in
        var segments: [OCRSegment] = []

        for line in row.lines {
            guard var last = segments.popLast() else {
                segments.append(OCRSegment(rowIndex: row.index, rect: line.rect, text: line.text))
                continue
            }

            let gap = max(CGFloat(0), line.rect.minX - last.rect.maxX)
            let rowHeight = max(last.rect.height, line.rect.height)
            if shouldJoinSameVisualLine(left: last, right: line, gap: gap, rowHeight: rowHeight) {
                last.rect = last.rect.union(line.rect)
                last.text = joinInline(last.text, line.text)
                segments.append(last)
            } else {
                segments.append(last)
                segments.append(OCRSegment(rowIndex: row.index, rect: line.rect, text: line.text))
            }
        }

        return segments
    }
}

private func shouldJoinSameVisualLine(left: OCRSegment, right: OCRLine, gap: CGFloat, rowHeight: CGFloat) -> Bool {
    if gap <= 0 {
        return true
    }

    let tightGap = max(CGFloat(0.018), rowHeight * 1.15)
    if gap <= tightGap {
        return true
    }

    let cautiousWordGap = max(CGFloat(0.026), rowHeight * 1.55)
    guard gap <= cautiousWordGap else {
        return false
    }

    return isLikelyInlineFragment(left.text) && isLikelyInlineFragment(right.text)
}

private func makeBlocks(from segments: [OCRSegment]) -> [OCRBlock] {
    var blocks: [OCRBlock] = []
    let sorted = segments.sorted(by: segmentReadingOrder)

    for segment in sorted {
        if let index = bestBlockIndex(for: segment, in: blocks) {
            blocks[index].add(segment)
        } else {
            blocks.append(OCRBlock(segment: segment))
        }
    }

    return blocks
}

private func bestBlockIndex(for segment: OCRSegment, in blocks: [OCRBlock]) -> Int? {
    blocks
        .enumerated()
        .compactMap { index, block -> (index: Int, score: CGFloat)? in
            guard canAdd(segment, to: block) else { return nil }
            return (index, blockScore(for: segment, in: block))
        }
        .min { $0.score < $1.score }?
        .index
}

private func canAdd(_ segment: OCRSegment, to block: OCRBlock) -> Bool {
    guard !block.segments.contains(where: { $0.rowIndex == segment.rowIndex }) else {
        return false
    }

    let overlap = horizontalOverlap(segment.rect, block.rect)
    let minWidth = max(CGFloat(0.001), min(segment.rect.width, block.rect.width))
    let overlapRatio = overlap / minWidth
    let leadingDelta = abs(segment.rect.minX - block.rect.minX)
    let centerDelta = abs(segment.rect.midX - block.rect.midX)
    let lineHeight = max(segment.rect.height, block.averageLineHeight)
    let leadingTolerance = max(CGFloat(0.035), lineHeight * 2.0)
    let centerTolerance = max(CGFloat(0.045), minWidth * 0.35)
    let blockIsWide = block.rect.width > 0.68
    let segmentIsWide = segment.rect.width > 0.68

    if blockIsWide, !segmentIsWide, leadingDelta > leadingTolerance {
        return false
    }
    if segmentIsWide, !blockIsWide, leadingDelta > leadingTolerance {
        return false
    }

    if overlapRatio >= 0.42 {
        return true
    }
    if leadingDelta <= leadingTolerance {
        return true
    }
    return centerDelta <= centerTolerance
}

private func blockScore(for segment: OCRSegment, in block: OCRBlock) -> CGFloat {
    let leadingDelta = abs(segment.rect.minX - block.rect.minX)
    let centerDelta = abs(segment.rect.midX - block.rect.midX)
    let verticalGap = max(CGFloat(0), block.rect.minY - segment.rect.maxY)
    return leadingDelta * 2.0 + centerDelta + verticalGap * 0.4
}

private func renderBlock(_ block: OCRBlock) -> String {
    let segments = block.segments.sorted(by: segmentReadingOrder)
    guard var output = segments.first?.text else { return "" }

    let preserveLines = shouldPreferLineBreaks(in: segments)
    var previous = segments[0]
    for segment in segments.dropFirst() {
        let boundary = boundaryBetween(
            previous: previous,
            next: segment,
            block: block,
            preserveLines: preserveLines
        )
        switch boundary {
        case .join:
            output = joinParagraphLine(output, segment.text)
        case .line:
            output += "\n\(segment.text)"
        case .paragraph:
            output += "\n\n\(segment.text)"
        }
        previous = segment
    }

    return output
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
}

private func boundaryBetween(
    previous: OCRSegment,
    next: OCRSegment,
    block: OCRBlock,
    preserveLines: Bool
) -> OCRBoundary {
    let verticalGap = max(CGFloat(0), previous.rect.minY - next.rect.maxY)
    let lineHeight = max(CGFloat(0.001), max(previous.rect.height, next.rect.height))
    let gapRatio = verticalGap / lineHeight

    if gapRatio > 1.15 || verticalGap > 0.052 {
        return .paragraph
    }
    if preserveLines {
        return gapRatio > 0.75 ? .paragraph : .line
    }
    if startsStructuredLine(next.text) || startsStructuredLine(previous.text) {
        return .line
    }
    if isShortUIBoundary(previous.text, next.text) {
        return .line
    }

    let leadingDelta = abs(previous.rect.minX - next.rect.minX)
    let blockWidth = max(CGFloat(0.001), block.rect.width)
    let previousFillsLine = previous.rect.width >= blockWidth * 0.58
    let leadingTolerance = max(CGFloat(0.04), lineHeight * 2.2)

    if leadingDelta > leadingTolerance {
        return previousEndsStrongly(previous.text) ? .paragraph : .line
    }
    if looksLikeHeading(previous.text, next: next.text, in: blockWidth, width: previous.rect.width) {
        return .paragraph
    }
    if previousFillsLine || !previousEndsStrongly(previous.text) || startsLikeContinuation(next.text) {
        return .join
    }
    return .line
}

private func shouldPreferLineBreaks(in segments: [OCRSegment]) -> Bool {
    guard segments.count >= 2 else { return false }

    let shortCount = segments.filter { looksLikeShortUILabel($0.text) || startsStructuredLine($0.text) }.count
    let shortRatio = Double(shortCount) / Double(segments.count)
    let averageLength = Double(segments.map { meaningfulLength($0.text) }.reduce(0, +)) / Double(segments.count)

    if segments.count <= 3 {
        return shortCount == segments.count && averageLength <= 22
    }
    return shortRatio >= 0.62 && averageLength <= 28
}

private func blockReadingOrder(_ left: OCRBlock, _ right: OCRBlock) -> Bool {
    let verticalOverlapAmount = verticalOverlap(left.rect, right.rect)
    let minHeight = max(CGFloat(0.001), min(left.rect.height, right.rect.height))
    if verticalOverlapAmount / minHeight > 0.28 {
        return left.rect.minX < right.rect.minX
    }

    let topDelta = abs(left.rect.maxY - right.rect.maxY)
    let lineHeight = max(left.averageLineHeight, right.averageLineHeight)
    if topDelta <= max(CGFloat(0.035), lineHeight * 2.0), abs(left.rect.minX - right.rect.minX) > 0.04 {
        return left.rect.minX < right.rect.minX
    }
    return left.rect.maxY > right.rect.maxY
}

private func segmentReadingOrder(_ left: OCRSegment, _ right: OCRSegment) -> Bool {
    let yDelta = abs(left.rect.midY - right.rect.midY)
    if yDelta > max(CGFloat(0.012), min(left.rect.height, right.rect.height) * 0.55) {
        return left.rect.midY > right.rect.midY
    }
    return left.rect.minX < right.rect.minX
}

private func horizontalOverlap(_ left: CGRect, _ right: CGRect) -> CGFloat {
    max(CGFloat(0), min(left.maxX, right.maxX) - max(left.minX, right.minX))
}

private func verticalOverlap(_ left: CGRect, _ right: CGRect) -> CGFloat {
    max(CGFloat(0), min(left.maxY, right.maxY) - max(left.minY, right.minY))
}

private func joinInline(_ left: String, _ right: String) -> String {
    let left = left.trimmingCharacters(in: .whitespacesAndNewlines)
    let right = right.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !left.isEmpty else { return right }
    guard !right.isEmpty else { return left }
    return left + (needsSpaceBetween(left, right) ? " " : "") + right
}

private func joinParagraphLine(_ left: String, _ right: String) -> String {
    let left = left.trimmingCharacters(in: .whitespacesAndNewlines)
    let right = right.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !left.isEmpty else { return right }
    guard !right.isEmpty else { return left }

    if left.hasSuffix("-"), startsWithLowercaseOrDigit(right) {
        return String(left.dropLast()) + right
    }
    return left + (needsSpaceBetween(left, right) ? " " : "") + right
}

private func needsSpaceBetween(_ left: String, _ right: String) -> Bool {
    guard let last = lastMeaningfulScalar(in: left),
          let first = firstMeaningfulScalar(in: right) else {
        return false
    }

    if isClosingPunctuation(first) || isOpeningPunctuation(last) {
        return false
    }
    if isCJK(last), isCJK(first) {
        return false
    }
    if isCJK(last), isCJKPunctuation(first) {
        return false
    }
    if isCJKPunctuation(last), isCJK(first) {
        return false
    }
    return true
}

private func isLikelyInlineFragment(_ text: String) -> Bool {
    let length = meaningfulLength(text)
    if length <= 3 {
        return true
    }
    if wordCount(text) == 1, length <= 14, !containsSentencePunctuation(text) {
        return true
    }
    return false
}

private func startsStructuredLine(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }

    if trimmed.range(of: #"^[-*•·●○]\s*\S"#, options: .regularExpression) != nil {
        return true
    }
    if trimmed.range(of: #"^\d{1,3}[\.)、]\s*\S"#, options: .regularExpression) != nil {
        return true
    }
    if trimmed.range(of: #"^[A-Za-z]\)\s*\S"#, options: .regularExpression) != nil {
        return true
    }
    return false
}

private func isShortUIBoundary(_ previous: String, _ next: String) -> Bool {
    looksLikeShortUILabel(previous) && looksLikeShortUILabel(next)
}

private func looksLikeShortUILabel(_ text: String) -> Bool {
    let length = meaningfulLength(text)
    guard length > 0 else { return false }
    if containsSentencePunctuation(text), length > 10 {
        return false
    }

    let cjkCount = text.unicodeScalars.filter(isCJK).count
    if cjkCount >= 10 {
        return false
    }
    if length <= 18 {
        return true
    }
    return wordCount(text) <= 3 && length <= 28
}

private func looksLikeHeading(_ text: String, next: String, in blockWidth: CGFloat, width: CGFloat) -> Bool {
    let length = meaningfulLength(text)
    guard length > 0, length <= 28 else { return false }
    guard !startsStructuredLine(text), !previousEndsStrongly(text) else { return false }

    let nextLength = meaningfulLength(next)
    if looksLikeShortUILabel(text), nextLength >= length + 6 {
        return true
    }
    return length <= 18 && width < blockWidth * 0.55 && nextLength > length
}

private func previousEndsStrongly(_ text: String) -> Bool {
    guard let last = lastMeaningfulScalar(in: text) else { return false }
    return CharacterSet(charactersIn: ".!?。！？；;…").contains(last)
}

private func containsSentencePunctuation(_ text: String) -> Bool {
    text.unicodeScalars.contains { CharacterSet(charactersIn: ".!?。！？；;，,、").contains($0) }
}

private func startsLikeContinuation(_ text: String) -> Bool {
    guard let first = firstMeaningfulScalar(in: text) else { return false }
    if isCJK(first) {
        return true
    }
    if (0x0061...0x007A).contains(first.value) || (0x0030...0x0039).contains(first.value) {
        return true
    }
    return CharacterSet(charactersIn: "，,.;:!?)]}）。！？；：").contains(first)
}

private func startsWithLowercaseOrDigit(_ text: String) -> Bool {
    guard let first = firstMeaningfulScalar(in: text) else { return false }
    return (0x0061...0x007A).contains(first.value) || (0x0030...0x0039).contains(first.value)
}

private func wordCount(_ text: String) -> Int {
    text.split { character in
        character.isWhitespace || character.isPunctuation
    }.count
}

private func meaningfulLength(_ text: String) -> Int {
    text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
}

private func firstMeaningfulScalar(in text: String) -> Unicode.Scalar? {
    text.unicodeScalars.first { !CharacterSet.whitespacesAndNewlines.contains($0) }
}

private func lastMeaningfulScalar(in text: String) -> Unicode.Scalar? {
    text.unicodeScalars.reversed().first { !CharacterSet.whitespacesAndNewlines.contains($0) }
}

private func isCJK(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF:
        return true
    default:
        return false
    }
}

private func isCJKPunctuation(_ scalar: Unicode.Scalar) -> Bool {
    CharacterSet(charactersIn: "，。！？；：、）】》」』").contains(scalar)
}

private func isClosingPunctuation(_ scalar: Unicode.Scalar) -> Bool {
    CharacterSet(charactersIn: ".,!?;:%)]}，。！？；：、）】》」』").contains(scalar)
}

private func isOpeningPunctuation(_ scalar: Unicode.Scalar) -> Bool {
    CharacterSet(charactersIn: "([{\u{300C}\u{300E}\u{300A}\u{3010}").contains(scalar)
}

private extension Array where Element == CGFloat {
    var average: CGFloat {
        guard !isEmpty else { return 0 }
        return reduce(0, +) / CGFloat(count)
    }
}
