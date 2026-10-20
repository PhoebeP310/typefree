import Foundation

/// 把分段 / 分句的识别结果拼成一段：中文直接相连；英文等靠空格分词的文字，段与段之间补一个空格。
/// 各段拼接前会去掉首尾空白（识别服务常在句尾带空格，如火山逐句结果 "Thank you. "），
/// 只用空串相连的话英文会粘成 "today.I think"、"hello" + "world" → "helloworld"。
public enum TranscriptJoiner {
    public static func join(_ parts: [String]) -> String {
        var result = ""
        for raw in parts {
            let part = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { continue }
            if let last = result.last, let first = part.first, needsSpace(between: last, and: first) {
                result.append(" ")
            }
            result += part
        }
        return result
    }

    /// 下一段以字母 / 数字开头，且上一段以字母 / 数字或英文标点结尾时才补空格；
    /// 任一边是中文（或全角标点）都不补，避免中文里冒出多余空格。
    static func needsSpace(between last: Character, and first: Character) -> Bool {
        guard isSpaceSeparatedWordCharacter(first) else { return false }
        return isSpaceSeparatedWordCharacter(last) || ".,!?;:)]}\"'%".contains(last)
    }

    /// 拉丁 / 希腊 / 西里尔等靠空格分词的字母和数字；中日韩文字不算
    private static func isSpaceSeparatedWordCharacter(_ c: Character) -> Bool {
        guard c.isLetter || c.isNumber, let scalar = c.unicodeScalars.first else { return false }
        return scalar.value < 0x2E80
    }
}
