import Foundation

/// Which icon a model gets. The model name decides first (a pi or OpenCode thread can run any model), the provider is the fallback.
public enum ModelFamily: String, Sendable, CaseIterable {
    case claude, openai, grok, qwen, gemini, glm, kimi, cursor, copilot, deepseek, llama, mistral, pi, other
}

public enum ModelInfo {
    public static func family(provider: String?, model: String?) -> ModelFamily {
        let m = (model ?? "").lowercased()
        let table: [(String, ModelFamily)] = [
            ("claude", .claude), ("gpt", .openai), ("codex", .openai), ("grok", .grok), ("qwen", .qwen), ("gemini", .gemini),
            ("glm", .glm), ("kimi", .kimi), ("composer", .cursor), ("copilot", .copilot), ("deepseek", .deepseek),
            ("llama", .llama), ("mistral", .mistral)]
        if let hit = table.first(where: { m.contains($0.0) }) { return hit.1 }
        switch (provider ?? "").lowercased() {
        case "claudeagent", "claude": return .claude
        case "codex": return .openai
        case "grok": return .grok
        case "cursor": return .cursor
        case "pi": return .pi
        default: return .other
        }
    }

    /// `claude-sonnet-5-5` → "Claude Sonnet 5.5", `ollama/qwen3.8-pi:latest` → "Qwen3.8 Pi", `gpt-6.1-sol` → "GPT 6.1 Sol".
    public static func displayName(model: String?) -> String {
        guard var m = model, !m.isEmpty else { return "Unknown model" }
        if let slash = m.lastIndex(of: "/") { m = String(m[m.index(after: slash)...]) }
        if m.hasSuffix(":latest") { m = String(m.dropLast(7)) }
        var out: [String] = []
        for t in m.split(separator: "-").map(String.init) {
            if t.allSatisfy(\.isNumber), let last = out.last, last.allSatisfy({ $0.isNumber || $0 == "." }) { out[out.count - 1] = last + "." + t }
            else { out.append(t) }
        }
        return out.map { t in
            if t.lowercased() == "gpt" { return "GPT" }
            guard let f = t.first, f.isLetter else { return t }
            return f.uppercased() + t.dropFirst()
        }.joined(separator: " ")
    }

    public static func providerName(_ provider: String?) -> String? {
        switch (provider ?? "").lowercased() {
        case "": return nil
        case "claudeagent": return "Claude"
        case "codex": return "Codex"
        case "pi": return "Pi"
        case "opencode": return "OpenCode"
        default: return provider.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        }
    }

    /// Hover text for the model icon. `executedModel` is only mentioned when it differs from the requested one.
    public static func hover(provider: String?, model: String?, executedModel: String?) -> String {
        var lines = [displayName(model: model)]
        if let p = providerName(provider) { lines.append(p) }
        if let e = executedModel, e != model { lines.append("Ran on \(displayName(model: e))") }
        return lines.joined(separator: "\n")
    }
}
