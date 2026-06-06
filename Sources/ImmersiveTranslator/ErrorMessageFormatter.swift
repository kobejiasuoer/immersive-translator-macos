import Foundation

enum ErrorMessageFormatter {
    static func message(for error: Error) -> String {
        if let translationError = error as? TranslationClientError {
            return translationMessage(for: translationError)
        }

        if let selectedTextError = error as? SelectedTextReaderError {
            return selectedTextError.localizedDescription
        }

        if let ocrError = error as? OCRError {
            return ocrError.localizedDescription
        }

        if let urlError = error as? URLError {
            return networkMessage(for: urlError)
        }

        if error is DecodingError {
            return "翻译接口返回格式不符合预期。请确认接口地址是 OpenAI Chat Completions 兼容格式。"
        }

        return "操作没有完成。请检查网络、权限和设置后重试。\n\n详细信息：\(error.localizedDescription)"
    }

    private static func translationMessage(for error: TranslationClientError) -> String {
        switch error {
        case .invalidEndpoint:
            return "接口地址不是有效 URL。请在设置里检查接口地址。"
        case .missingAPIKey:
            return "还没有配置 API Key。请先打开设置并填入 OpenAI 或兼容服务的 API Key。"
        case .badResponse(let statusCode, let message):
            var lines: [String]
            switch statusCode {
            case 401, 403:
                lines = ["翻译服务拒绝了请求。请检查 API Key 是否有效，以及账号是否有权限。"]
            case 404:
                lines = ["没有找到翻译接口或模型。请检查接口地址和模型名。"]
            case 408:
                lines = ["翻译请求超时。可以稍后重试，或检查网络连接。"]
            case 429:
                lines = ["翻译请求受限。可能是请求过于频繁、额度不足，或服务暂时限流。"]
            case 500...599:
                lines = ["翻译服务暂时不可用。请稍后重试。"]
            default:
                lines = ["翻译接口返回 HTTP \(statusCode)。请检查 API Key、模型名和接口地址。"]
            }
            if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("接口提示：\(message)")
            }
            return lines.joined(separator: "\n\n")
        case .emptyTranslation:
            return "翻译接口返回了空结果。可以重新翻译一次，或换一个模型试试。"
        case .invalidResponse:
            return "翻译接口返回格式不符合预期。请确认接口地址是 OpenAI Chat Completions 兼容格式。"
        }
    }

    private static func networkMessage(for error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet:
            return "当前没有网络连接。联网后再试一次。"
        case .timedOut:
            return "翻译请求超时。可以稍后重试，或检查接口地址是否可访问。"
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "无法连接到翻译服务。请检查接口地址和网络连接。"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid:
            return "无法建立安全连接。请检查接口地址是否使用可信 HTTPS 服务。"
        default:
            return "网络请求失败。请检查网络连接和接口地址。\n\n详细信息：\(error.localizedDescription)"
        }
    }
}
