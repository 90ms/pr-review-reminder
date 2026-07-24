import Foundation

public enum Severity: String, Sendable, Codable, CaseIterable {
    case high, medium, low

    /// Lenient decoding: unknown/missing severities fall back to `.medium`.
    public init(lenient raw: String?) {
        switch raw?.lowercased() {
        case "high", "critical", "blocker": self = .high
        case "low", "nit", "minor": self = .low
        default: self = .medium
        }
    }
}

public struct ReviewPoint: Sendable, Codable, Equatable, Identifiable {
    public var id: String { "\(severity.rawValue):\(text)" }
    public let severity: Severity
    public let text: String

    public init(severity: Severity, text: String) {
        self.severity = severity
        self.text = text
    }
}

public struct InlineComment: Sendable, Codable, Equatable, Identifiable {
    public var id: String { "\(path):\(line):\(side)" }
    public let path: String
    public let line: Int
    public let side: String   // "RIGHT" (added/context) or "LEFT" (removed)
    public var body: String

    public init(path: String, line: Int, side: String = "RIGHT", body: String) {
        self.path = path
        self.line = line
        self.side = side
        self.body = body
    }
}

/// Token usage and (when available) cost of an AI analysis run.
public struct AIUsage: Sendable, Codable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var totalTokens: Int?
    public var costUSD: Double?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, totalTokens: Int? = nil, costUSD: Double? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.costUSD = costUSD
    }

    /// Best-known total token count.
    public var tokens: Int? {
        if let totalTokens { return totalTokens }
        if inputTokens != nil || outputTokens != nil { return (inputTokens ?? 0) + (outputTokens ?? 0) }
        return nil
    }

    /// Compact label, e.g. "12,345 tokens · $0.0123" or "34,772 tokens".
    public func label(costUnavailable: String = "", tokensUnit: String = "tokens") -> String {
        var parts: [String] = []
        if let t = tokens {
            parts.append("\(t.formatted(.number)) \(tokensUnit)")
        }
        if let c = costUSD {
            parts.append(String(format: "$%.4f", c))
        } else if !costUnavailable.isEmpty, tokens != nil {
            parts.append(costUnavailable)
        }
        return parts.joined(separator: " · ")
    }
}

/// The structured result of an AI analysis of a pull request.
public struct Analysis: Sendable, Codable, Equatable {
    public let summary: String
    public let reviewPoints: [ReviewPoint]
    public let inlineComments: [InlineComment]

    public init(summary: String, reviewPoints: [ReviewPoint] = [], inlineComments: [InlineComment] = []) {
        self.summary = summary
        self.reviewPoints = reviewPoints
        self.inlineComments = inlineComments
    }
}
