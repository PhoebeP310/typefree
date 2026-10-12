import Foundation

/// Qwen Omni 一步直出：把录音样本直接喂给多模态模型，跳过单独的 ASR 步骤
public final class OmniTranscriber {
    public enum OmniError: Error, CustomStringConvertible {
        case noAPIKey
        case encodingFailed
        case noData
        case parseError
        case empty
        case http(status: Int, body: String?)

        public var description: String {
            switch self {
            case .noAPIKey: return "DASHSCOPE_API_KEY missing"
            case .encodingFailed: return "WAV encoding failed"
            case .noData: return "no response data"
            case .parseError: return "response parse error"
            case .empty: return "empty response"
            case .http(let status, _):
                return "HTTP \(status)"
            }
        }
    }

    public var debugLog: ((String) -> Void)?

    private let endpoint = URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!
    private let defaultModel = "qwen3.5-omni-flash"
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func isConfigured() -> Bool {
        let key = VoicePolishConfig.shared.string(forKey: "dashscope_api_key", envKey: "DASHSCOPE_API_KEY")
        return !(key?.isEmpty ?? true)
    }

    public func process(samples: [Float], sampleRate: Int = 16000, completion: @escaping (Result<String, Error>) -> Void) {
        let config = VoicePolishConfig.shared
        guard let apiKey = config.string(forKey: "dashscope_api_key", envKey: "DASHSCOPE_API_KEY"),
              !apiKey.isEmpty else {
            debugLog?("OmniTranscriber not configured (missing dashscope_api_key)")
            completion(.failure(OmniError.noAPIKey))
            return
        }
        let model = config.string(forKey: "qwen_omni_model") ?? defaultModel

        guard let wavData = WAVEncoder.makeWAVData(from: samples, sampleRate: sampleRate) else {
            completion(.failure(OmniError.encodingFailed))
            return
        }
        let base64 = wavData.base64EncodedString()

        debugLog?("Omni processing started (model=\(model), samples=\(samples.count), wav=\(wavData.count) bytes)")
        let started = Date()

        // 个人词库注入：识别 + 整理一步完成，词表跟着 system 提示走
        var systemPrompt = Self.systemPrompt
        if let sentence = PersonalVocabulary.asrContextSentence() {
            systemPrompt += """


            ## 用户个人词库
            \(sentence)。听到读音相近的内容时，优先采用这些写法，但不要凭空加入用户没说过的词。
            """
        }
        // 风格画像：识别+整理一步完成，让成稿贴合用户的说话习惯。
        // 观察期注入默认关闭（先学不用），与 AIPolisher 同一开关，确认画像靠谱后再打开。
        if VoicePolishConfig.shared.bool(forKey: "style_profile_injection_enabled", defaultValue: false),
           let styleSection = StyleProfileStore.promptSection() {
            systemPrompt += "\n\n" + styleSection
        }

        let body: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "system",
                    "content": systemPrompt
                ],
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "input_audio",
                            "input_audio": [
                                "data": "data:;base64,\(base64)",
                                "format": "wav"
                            ]
                        ],
                        [
                            "type": "text",
                            "text": "请按上面的规则把这段录音整理成好读的文本。"
                        ]
                    ]
                ]
            ],
            "modalities": ["text"],
            "stream": false,
            "temperature": 0.5,
            "top_p": 0.8,
            "result_format": "message",
            "enable_thinking": false
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 90

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(error))
            return
        }

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)

            if let error = error {
                self.debugLog?("Omni request failed in \(elapsedMs)ms: \(error)")
                completion(.failure(error))
                return
            }
            guard let data = data else {
                self.debugLog?("Omni returned no data after \(elapsedMs)ms")
                completion(.failure(OmniError.noData))
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                let bodyString = String(data: data, encoding: .utf8)
                self.debugLog?("Omni API error: status=\(http.statusCode), responseBytes=\(data.count)")
                completion(.failure(OmniError.http(status: http.statusCode, body: bodyString)))
                return
            }

            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let firstChoice = choices.first,
                      let message = firstChoice["message"] as? [String: Any] else {
                    self.debugLog?("Omni parse error after \(elapsedMs)ms, responseBytes=\(data.count)")
                    completion(.failure(OmniError.parseError))
                    return
                }

                // content 可能是 string 或者 多模态分段数组
                let text: String
                if let str = message["content"] as? String {
                    text = str
                } else if let arr = message["content"] as? [[String: Any]] {
                    text = arr.compactMap { $0["text"] as? String }.joined()
                } else {
                    text = ""
                }

                let usage = json["usage"] as? [String: Any]
                let inputTokens = usage?["prompt_tokens"] as? Int ?? 0
                let outputTokens = usage?["completion_tokens"] as? Int ?? 0
                let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmed = raw.isEmpty ? "" : (PersonalVocabulary.removingContextEcho(raw) ?? "")

                if trimmed.isEmpty {
                    self.debugLog?("Omni returned empty text in \(elapsedMs)ms")
                    completion(.failure(OmniError.empty))
                    return
                }

                self.debugLog?("Omni done in \(elapsedMs)ms: chars=\(trimmed.count), tokens=\(inputTokens)/\(outputTokens)")
                completion(.success(trimmed))
            } catch {
                self.debugLog?("Omni JSON exception after \(elapsedMs)ms: \(error)")
                completion(.failure(error))
            }
        }.resume()
    }

    private static let systemPrompt = """
    你是语音转文字的整理助手。用户口述了一段话，你的任务是清除口误和明显冗余，但**保持用户原本的口语风格**。你不是在写公文，是在帮用户把口语整理成"他自己说的话"，只是更通顺。

    ## 你要做的
    - 修正口误：用户自己纠正后，留下最终意图（"周三…嗯不对…周四" → "周四"）
    - 删冗余：删重复的词和无意义语气词（"嗯""啊""那个""然后"）
    - 修标点：让断句更自然
    - 数字：汉字数字转阿拉伯数字（"两到三次"→"2 到 3 次"），成语除外
    - 并列内容：用户在明显列举时（"第一…第二…"），用编号列表

    ## 必须保留（绝对不要改！）
    - 口语助词："吧""呢""啊""嘛""哦""喏"等表达语气的字
    - 用户的核心用词：说"看看"不要改成"查看"，说"是不是"不要改成"是否"，说"全模型"不要改成"完整测试"
    - 用户的句式：说"我打算…"就保留"我打算"，说"让你…"就保留"让你"

    ## 你不要做的
    - 不要总结、不要概括（你不是写摘要）
    - 不要把口语换成书面语
    - 不要添加用户没说的内容，包括"好的""了解""收到"这种回应词
    - 不要回答用户的问题
    - 不要用加粗、标题等富文本格式

    ## 示例

    输入：我们周三开会吧。嗯，不对，还是周四吧。
    输出：我们周四开会吧。

    输入：我打算后天去吃饭吧，还是大后天？
    输出：我打算大后天去吃饭吧。

    输入：那个，我感觉这个项目，就是它的进度有点慢，可能需要再加点人。
    输出：我感觉这个项目的进度有点慢，可能需要再加点人。

    输入：那我先测试一下，让你在 iPhone 和 Mac 上各自跑一次那个对话的全模型，看看有三点吧。第一点是不是会主动分段。第二点是不是会把那个并列的一二三列表列出来。第三点就是整体的对话流畅度有没有问题。
    输出：那我先测试一下，让你在 iPhone 和 Mac 上各自跑一次那个对话的全模型，看看有三点：
    1. 是不是会主动分段
    2. 是不是会把那个并列的一二三列表列出来
    3. 整体的对话流畅度有没有问题
    """
}
