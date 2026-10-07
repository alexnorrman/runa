import RunaCore
import RunaDesign
import SwiftUI

struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @State private var error: String?

    var body: some View {
        VStack(spacing: RunaSpacing.xl) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 88, height: 88)
            VStack(spacing: RunaSpacing.s) {
                Text("Welcome to Runa").runaTitle(RunaFont.title1)
                Text("Keep every UI string for iOS, Android and the web in one place you own, link it to your Figma designs, and let AI draft the translations.")
                    .font(RunaFont.body).foregroundStyle(RunaColor.textTertiary).multilineTextAlignment(.center).frame(maxWidth: 460)
            }
            VStack(spacing: RunaSpacing.s) {
                Button { app.isAddingProject = true } label: {
                    Label("Connect a Google Sheet or File", systemImage: "plus").frame(width: 260)
                }
                .buttonStyle(RunaButtonStyle(.primary, size: .large))
                Button {
                    do { app.add(try DemoProject.create()) } catch { self.error = error.localizedDescription }
                } label: {
                    Text("Explore a Demo Project").frame(width: 260)
                }
                .buttonStyle(RunaButtonStyle(.secondary, size: .large))
            }
            if let error { Text(error).font(RunaFont.small).foregroundStyle(RunaColor.missing) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RunaColor.appBackground)
    }
}
