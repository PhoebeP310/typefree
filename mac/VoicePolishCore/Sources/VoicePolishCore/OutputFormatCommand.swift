import Foundation

// 本地改动：格式口令「改成要点」「结论先行」。
// 和「用英文」同一套识别规则（只认句首/句尾、句首口令后要停顿、前面紧跟否定词不算、去掉口令后要有正文），
// 可以和语言口令叠加（「……，改成要点，用英文」「用英文，结论先行：……」）。
// 识别逻辑单独放在本文件，没去改上游的 OutputLanguageCommand.detect，方便以后合并上游。

/// 本次输出的格式要求
public enum OutputFormat: String, CaseIterable, Equatable {
    case keyPoints          // 改成要点
    case conclusionFirst    // 结论先行

    /// 胶囊 / 日志上的短名
    public var name: String {
        switch self {
        case .keyPoints: return "要点"
        case .conclusionFirst: return "结论先行"
        }
    }

    public var phrases: [String] {
        switch self {
        case .keyPoints: return ["改成要点", "整理成要点", "列成要点"]
        case .conclusionFirst: return ["结论先行", "先说结论"]
        }
    }
}

public struct OutputFormatCommand: Equatable {
    public let format: OutputFormat
    public let position: OutputLanguageCommand.Position
    public let matchedPhrase: String
    /// 去掉口令后的正文（已去掉口令旁边的标点）
    public let strippedText: String

    public static func detect(in text: String, formats: [OutputFormat] = OutputFormat.allCases) -> OutputFormatCommand? {
        let pairs = formats.flatMap { f in f.phrases.map { ($0, f) } }
        guard let m = VoiceCommandMatcher.match(in: text, pairs: pairs) else { return nil }
        return OutputFormatCommand(format: m.value, position: m.position, matchedPhrase: m.phrase, strippedText: m.strippedText)
    }
}

/// 本地改动：一句话里的全部口令（语言 + 格式，各最多一个），以及都剥掉后的正文。
public struct VoiceCommands: Equatable {
    public var language: OutputLanguageCommand?
    public var format: OutputFormatCommand?
    /// 剥掉所有口令后的正文；一个口令都没有时 = 原文
    public var strippedText: String

    public var isEmpty: Bool { language == nil && format == nil }

    /// 轮流剥：先看语言口令、再看格式口令，剥掉一个后对剩下的正文再试另一个。
    /// 「……，改成要点，用英文」→ 先剥句尾「用英文」，剩「……，改成要点」再剥「改成要点」。
    public static func parse(_ text: String,
                             languages: [OutputLanguage] = OutputLanguage.builtin,
                             formats: [OutputFormat] = OutputFormat.allCases) -> VoiceCommands {
        var result = VoiceCommands(language: nil, format: nil, strippedText: text)
        for _ in 0..<2 {
            var progressed = false
            if result.language == nil, !languages.isEmpty,
               let cmd = OutputLanguageCommand.detect(in: result.strippedText, languages: languages) {
                result.language = cmd
                result.strippedText = cmd.strippedText
                progressed = true
            }
            if result.format == nil, !formats.isEmpty,
               let cmd = OutputFormatCommand.detect(in: result.strippedText, formats: formats) {
                result.format = cmd
                result.strippedText = cmd.strippedText
                progressed = true
            }
            if !progressed { break }
        }
        // 剥完只剩另一个口令（「改成要点，用英文」「用英文，结论先行」）= 整句只有口令，当正文，什么都不剥
        if !result.isEmpty {
            let rest = OutputLanguageCommand.trimEdges(OutputLanguageCommand.stripTrailingFillers(result.strippedText)).lowercased()
            let allPhrases = languages.filter(\.enabled).flatMap(\.phrases) + formats.flatMap(\.phrases)
            if allPhrases.contains(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == rest }) {
                return VoiceCommands(language: nil, format: nil, strippedText: text)
            }
        }
        return result
    }
}

/// 本地改动：OutputLanguageCommand.detect 的通用版（同样的规则，口令→值的映射由调用方给）。
/// 复用 OutputLanguageCommand 里的边界/否定/正文判定小函数，规则只有一份。
enum VoiceCommandMatcher {
    struct Match<T> {
        let value: T
        let position: OutputLanguageCommand.Position
        let phrase: String
        let strippedText: String
    }

    static func match<T>(in text: String, pairs rawPairs: [(String, T)]) -> Match<T>? {
        typealias R = OutputLanguageCommand
        let trimmed = R.trimEdges(text)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        let withoutFillers = R.stripTrailingFillers(trimmed)
        let trailingCandidates: [String] = withoutFillers == trimmed ? [trimmed] : [trimmed, withoutFillers]
        let pairs = rawPairs
            .map { ($0.0.trimmingCharacters(in: .whitespaces), $0.1) }
            .filter { !$0.0.isEmpty }
            .sorted { $0.0.count > $1.0.count }   // 长口令优先

        for (phrase, value) in pairs {
            let p = phrase.lowercased()
            let needsPunctuation = phrase.unicodeScalars.contains { R.isASCIILetter($0) }
            for candidate in trailingCandidates where candidate.lowercased().hasSuffix(p) {
                let bodyEnd = candidate.index(candidate.endIndex, offsetBy: -phrase.count)
                let body = String(candidate[..<bodyEnd])
                let boundaryOK = !needsPunctuation || R.hasPunctuationBoundary(body.unicodeScalars.reversed())
                if boundaryOK, !R.isNegated(before: body), let stripped = R.validBody(R.trimEdges(body)) {
                    return Match(value: value, position: .trailing, phrase: phrase, strippedText: stripped)
                }
            }
            if lower.hasPrefix(p) {
                let afterStart = trimmed.index(trimmed.startIndex, offsetBy: phrase.count)
                let rest = String(trimmed[afterStart...])
                let boundaryOK = needsPunctuation
                    ? R.hasPunctuationBoundary(rest.unicodeScalars)
                    : (rest.unicodeScalars.first.map(R.isSeparator) ?? false)
                if boundaryOK, let stripped = R.validBody(R.trimEdges(rest)) {
                    return Match(value: value, position: .leading, phrase: phrase, strippedText: stripped)
                }
            }
        }
        return nil
    }
}
