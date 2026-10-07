import Foundation

/// Where a key is used in a Figma design, captured by the Figma plugin.
public struct FigmaContext: Hashable, Codable, Sendable {
    public var url: String
    public var fileKey: String
    /// Node id in API form, `12:34`.
    public var nodeId: String
    public var pageName: String?
    public var frameName: String?
    public var nodePath: String?
    public var width: Double?
    public var height: Double?
    public var fontSize: Double?
    public var siblingTexts: [String]
    public var linkedAt: Date?
    public var linkedBy: String?

    public init(
        url: String, fileKey: String, nodeId: String, pageName: String? = nil, frameName: String? = nil,
        nodePath: String? = nil, width: Double? = nil, height: Double? = nil, fontSize: Double? = nil,
        siblingTexts: [String] = [], linkedAt: Date? = nil, linkedBy: String? = nil
    ) {
        self.url = url
        self.fileKey = fileKey
        self.nodeId = nodeId
        self.pageName = pageName
        self.frameName = frameName
        self.nodePath = nodePath
        self.width = width
        self.height = height
        self.fontSize = fontSize
        self.siblingTexts = siblingTexts
        self.linkedAt = linkedAt
        self.linkedBy = linkedBy
    }

    /// Builds a minimal context from a Figma link such as
    /// `https://www.figma.com/design/AbC123/Checkout?node-id=12-34`.
    public init?(url string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
            let host = components.host, host == "figma.com" || host.hasSuffix(".figma.com")
        else { return nil }
        let segments = components.path.split(separator: "/").map(String.init)
        guard let kindIndex = segments.firstIndex(where: { ["design", "file", "proto", "board"].contains($0) }),
            segments.count > kindIndex + 1
        else { return nil }
        let fileKey = segments[kindIndex + 1]
        guard let rawNode = components.queryItems?.first(where: { $0.name == "node-id" })?.value, !rawNode.isEmpty
        else { return nil }
        self.init(url: trimmed, fileKey: fileKey, nodeId: rawNode.replacingOccurrences(of: "-", with: ":"))
    }

    /// A short label such as "Checkout / Summary".
    public var label: String {
        [pageName, frameName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " / ")
    }
}
