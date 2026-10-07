import RunaCore
import RunaDesign
import SwiftUI

struct FigmaContextCard: View {
    @Environment(AppModel.self) private var app
    let context: FigmaContext
    @State private var image: NSImage?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                RunaColor.hover
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else if let problem {
                    Text(problem).font(RunaFont.small).foregroundStyle(RunaColor.textTertiary).multilineTextAlignment(.center).padding()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: image == nil ? 70 : 180)
            .clipped()
            HStack(spacing: RunaSpacing.s) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(context.label.isEmpty ? "Figma node \(context.nodeId)" : context.label)
                        .font(RunaFont.smallMedium).foregroundStyle(RunaColor.textPrimary).lineLimit(1)
                    let size = [context.width.map { "\(Int($0))×\(Int(context.height ?? 0))" }, context.fontSize.map { "\(Int($0))pt" }]
                        .compactMap { $0 }.joined(separator: " · ")
                    Text([context.nodePath, size.isEmpty ? nil : size].compactMap { $0 }.joined(separator: "  ·  "))
                        .font(RunaFont.font(size: 11)).foregroundStyle(RunaColor.textTertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if let url = URL(string: context.url) {
                    Button("Open") { NSWorkspace.shared.open(url) }.buttonStyle(.runa(.secondary, size: .small))
                }
            }
            .padding(RunaSpacing.s)
        }
        .background(RoundedRectangle(cornerRadius: RunaRadius.card).fill(RunaColor.elevated))
        .clipShape(RoundedRectangle(cornerRadius: RunaRadius.card))
        .overlay(RoundedRectangle(cornerRadius: RunaRadius.card).strokeBorder(RunaColor.borderSubtle))
        .task(id: context.url) {
            do {
                let data = try await FigmaImages.shared.png(fileKey: context.fileKey, nodeId: context.frameId ?? context.nodeId, token: app.figmaToken)
                image = NSImage(data: data)
            } catch {
                problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
