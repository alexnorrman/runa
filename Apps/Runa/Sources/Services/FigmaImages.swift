import AppKit
import Foundation
import RunaCore

/// Renders Figma frames through the REST API with the user's personal access token and caches
/// the PNGs locally. Nothing is uploaded anywhere.
actor FigmaImages {
    static let shared = FigmaImages()

    enum Failure: LocalizedError {
        case noToken, notRendered, http(Int)
        var errorDescription: String? {
            switch self {
            case .noToken: "Add a Figma access token in Settings → Figma to see screenshots."
            case .notRendered: "Figma could not render this frame."
            case .http(403): "The Figma token cannot open this file."
            case .http(let status): "Figma returned \(status)."
            }
        }
    }

    func png(fileKey: String, nodeId: String, token: String?) async throws -> Data {
        let cacheURL = Storage.figmaImages.appendingPathComponent("\(fileKey)_\(nodeId.replacingOccurrences(of: ":", with: "-")).png")
        if let data = try? Data(contentsOf: cacheURL), let attributes = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
           let modified = attributes[.modificationDate] as? Date, Date().timeIntervalSince(modified) < 24 * 3600
        {
            return data
        }
        guard let token, !token.isEmpty else { throw Failure.noToken }
        var components = URLComponents(string: "https://api.figma.com/v1/images/\(fileKey)")!
        components.queryItems = [URLQueryItem(name: "ids", value: nodeId), URLQueryItem(name: "format", value: "png"),
                                 URLQueryItem(name: "scale", value: "1")]
        var request = URLRequest(url: components.url!)
        request.setValue(token, forHTTPHeaderField: "X-Figma-Token")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.http(status) }
        guard let json = try? JSONValue.parse(data), let link = json["images"]?[nodeId]?.stringValue, let url = URL(string: link) else {
            throw Failure.notRendered
        }
        let (png, _) = try await URLSession.shared.data(from: url)
        try? png.write(to: cacheURL, options: .atomic)
        return png
    }

    /// Screenshot to send to an AI model: the frame when known, else the text node itself.
    func translationImage(for context: FigmaContext, token: String?) async -> TranslationImage? {
        guard let data = try? await png(fileKey: context.fileKey, nodeId: context.frameId ?? context.nodeId, token: token) else { return nil }
        let caption = [context.pageName, context.frameName].compactMap { $0 }.joined(separator: " / ")
        return TranslationImage(data: downscaled(data, maxDimension: 1400) ?? data, caption: caption.isEmpty ? "the design" : "the \(caption) screen")
    }

    private func downscaled(_ data: Data, maxDimension: CGFloat) -> Data? {
        guard let image = NSImage(data: data), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = CGFloat(cg.width), height = CGFloat(cg.height)
        let scale = min(1, maxDimension / max(width, height))
        if scale >= 1 { return data }
        let size = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(origin: .zero, size: size))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
    }
}
