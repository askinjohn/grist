import Foundation

class OllamaClient: @unchecked Sendable {
    static let shared = OllamaClient()
    
    private init() {}
    
    // MARK: - Preferences
    private var isOllama: Bool {
        return (UserDefaults.standard.string(forKey: "aiProviderType") ?? "Ollama") == "Ollama"
    }
    private var ollamaBaseURL: String {
        return UserDefaults.standard.string(forKey: "OllamaURL") ?? "http://127.0.0.1:11434"
    }
    private var openAIBaseURL: String {
        return UserDefaults.standard.string(forKey: "openAIBaseURL") ?? "https://api.openai.com/v1"
    }
    private var openAIAPIKey: String {
        return UserDefaults.standard.string(forKey: "openAIAPIKey") ?? ""
    }
    private var openAIModel: String {
        return UserDefaults.standard.string(forKey: "openAIModel") ?? "gpt-4o"
    }
    
    // MARK: - Shared Structs
    struct OllamaChatMessage: Codable {
        let role: String
        let content: String
    }
    
    // MARK: - Ollama Structs
    struct OllamaRequest: Encodable {
        let model: String
        let prompt: String
        let stream: Bool
    }
    struct OllamaResponse: Decodable {
        let response: String
    }
    struct OllamaChatRequest: Encodable {
        let model: String
        let messages: [OllamaChatMessage]
        let stream: Bool
    }
    struct OllamaChatResponse: Decodable {
        let message: OllamaChatMessage
    }
    struct OllamaEmbeddingRequest: Encodable {
        let model: String
        let prompt: String
    }
    struct OllamaEmbeddingResponse: Decodable {
        let embedding: [Double]
    }
    struct OllamaTagsResponse: Decodable {
        let models: [OllamaModel]
    }
    struct OllamaModel: Decodable {
        let name: String
    }
    
    // MARK: - OpenAI Structs
    struct OpenAIChatRequest: Encodable {
        let model: String
        let messages: [OllamaChatMessage]
        let stream: Bool
    }
    struct OpenAIChatResponse: Decodable {
        struct Choice: Decodable {
            let message: OllamaChatMessage
        }
        let choices: [Choice]
    }
    struct OpenAIModelsResponse: Decodable {
        struct ModelInfo: Decodable {
            let id: String
        }
        let data: [ModelInfo]
    }
    struct OpenAIEmbeddingRequest: Encodable {
        let model: String
        let input: String
    }
    struct OpenAIEmbeddingResponse: Decodable {
        struct EmbeddingData: Decodable {
            let embedding: [Double]
        }
        let data: [EmbeddingData]
    }
    
    // MARK: - Methods
    
    func getModels() async throws -> [String] {
        if isOllama {
            let url = URL(string: "\(ollamaBaseURL)/api/tags")!
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 10
            
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            
            let tagsResponse = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
            return tagsResponse.models.map { $0.name }
        } else {
            let url = URL(string: "\(openAIBaseURL)/models")!
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 10
            if !openAIAPIKey.isEmpty {
                request.setValue("Bearer \(openAIAPIKey)", forHTTPHeaderField: "Authorization")
            }
            
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    let tags = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
                    var models = tags.data.map { $0.id }
                    if models.isEmpty { models = [openAIModel] }
                    return models
                }
            } catch {
                print("[OllamaClient] Could not fetch OpenAI models, falling back to setting default.")
            }
            return [openAIModel]
        }
    }
    
    func enhance(transcript: String, notes: String, template: String, customPrompt: String? = nil, model: String) async throws -> String {
        print("[OllamaClient] Starting AI enhancement using model: \(model)...")
        
        var prompt = ""
        if let custom = customPrompt, !custom.isEmpty {
            prompt = """
            <system_instructions>
            \(custom)
            </system_instructions>
            
            <raw_transcript>
            \(transcript)
            </raw_transcript>
            
            <user_manual_notes>
            \(notes.isEmpty ? "(None provided)" : notes)
            </user_manual_notes>
            
            Output ONLY the requested summary. No explanations.
            """
        } else {
            prompt = """
            <system_instructions>
            You are an expert AI meeting assistant. Your task is to synthesize the raw transcript and manual notes into a beautiful, structured Markdown summary.
            
            Follow these strict rules:
            1. Format the summary according to the style: "\(template)".
            2. Combine points logically, correcting any garbled transcript words using context.
            3. Do NOT include metadata, system instructions, or the prompt itself in the summary.
            4. Output ONLY the final clean Markdown summary. No chat or explanations.
            </system_instructions>
            
            <raw_transcript>
            \(transcript)
            </raw_transcript>
            
            <user_manual_notes>
            \(notes.isEmpty ? "(None provided)" : notes)
            </user_manual_notes>
            
            Markdown Summary:
            """
        }
        
        if isOllama {
            let url = URL(string: "\(ollamaBaseURL)/api/generate")!
            let payload = OllamaRequest(model: model, prompt: prompt, stream: false)
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(payload)
            request.timeoutInterval = 60
            
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw NSError(domain: "OllamaClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to connect to local Ollama."])
            }
            let decoded = try JSONDecoder().decode(OllamaResponse.self, from: data)
            return decoded.response.trimmingCharacters(in: .whitespacesAndNewlines)
            
        } else {
            let url = URL(string: "\(openAIBaseURL)/chat/completions")!
            let msg = OllamaChatMessage(role: "user", content: prompt)
            let actualModel = model.isEmpty ? openAIModel : model
            let payload = OpenAIChatRequest(model: actualModel, messages: [msg], stream: false)
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !openAIAPIKey.isEmpty {
                request.setValue("Bearer \(openAIAPIKey)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try JSONEncoder().encode(payload)
            request.timeoutInterval = 60
            
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw NSError(domain: "OllamaClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to connect to OpenAI endpoint."])
            }
            let decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
            return decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }
    
    func chat(messages: [OllamaChatMessage], model: String) async throws -> OllamaChatMessage {
        print("[OllamaClient] Starting AI chat using model: \(model)...")
        
        if isOllama {
            let url = URL(string: "\(ollamaBaseURL)/api/chat")!
            let payload = OllamaChatRequest(model: model, messages: messages, stream: false)
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(payload)
            request.timeoutInterval = 60
            
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw NSError(domain: "OllamaClient", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to connect to Ollama Chat API."])
            }
            let decoded = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
            return decoded.message
            
        } else {
            let url = URL(string: "\(openAIBaseURL)/chat/completions")!
            let actualModel = model.isEmpty ? openAIModel : model
            let payload = OpenAIChatRequest(model: actualModel, messages: messages, stream: false)
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !openAIAPIKey.isEmpty {
                request.setValue("Bearer \(openAIAPIKey)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try JSONEncoder().encode(payload)
            request.timeoutInterval = 60
            
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw NSError(domain: "OllamaClient", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to connect to OpenAI Chat API."])
            }
            let decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
            return decoded.choices.first?.message ?? OllamaChatMessage(role: "assistant", content: "")
        }
    }
    
    func getEmbedding(text: String, model: String = "nomic-embed-text") async throws -> [Double] {
        if isOllama {
            let url = URL(string: "\(ollamaBaseURL)/api/embeddings")!
            let payload = OllamaEmbeddingRequest(model: model, prompt: text)
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(payload)
            request.timeoutInterval = 30
            
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw NSError(domain: "OllamaClient", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch embeddings from Ollama."])
            }
            let decoded = try JSONDecoder().decode(OllamaEmbeddingResponse.self, from: data)
            return decoded.embedding
            
        } else {
            let url = URL(string: "\(openAIBaseURL)/embeddings")!
            // Note: For OpenAI compatible embeddings, the model might need to be explicitly set
            // usually to text-embedding-ada-002 or text-embedding-3-small, but we use what the user passed
            // if we are in generic mode, it might fail. We default to 'text-embedding-3-small' if it's the nomic default.
            let actualModel = model == "nomic-embed-text" ? "text-embedding-3-small" : model
            let payload = OpenAIEmbeddingRequest(model: actualModel, input: text)
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !openAIAPIKey.isEmpty {
                request.setValue("Bearer \(openAIAPIKey)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try JSONEncoder().encode(payload)
            request.timeoutInterval = 30
            
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw NSError(domain: "OllamaClient", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch embeddings from OpenAI."])
            }
            let decoded = try JSONDecoder().decode(OpenAIEmbeddingResponse.self, from: data)
            return decoded.data.first?.embedding ?? []
        }
    }
}
