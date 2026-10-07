import RunaCore
import SwiftUI

// MARK: Status

extension TranslationStatus {
    public var color: Color {
        switch self {
        case .missing: RunaColor.missing
        case .machine: RunaColor.machine
        case .needsReview: RunaColor.review
        case .approved: RunaColor.approved
        }
    }
}

/// A small status dot. Missing values are hollow, so rows read at a glance without color too.
public struct StatusDot: View {
    let status: TranslationStatus
    let size: CGFloat

    public init(_ status: TranslationStatus, size: CGFloat = 7) {
        self.status = status
        self.size = size
    }

    public var body: some View {
        ZStack {
            if status == .missing {
                Circle().strokeBorder(status.color, lineWidth: 1.4)
            } else if status == .needsReview || status == .machine {
                Circle().strokeBorder(status.color, lineWidth: 1.4)
                HalfCircle().fill(status.color)
            } else {
                Circle().fill(status.color)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(status.displayName)
    }

    struct HalfCircle: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2, startAngle: .degrees(-90), endAngle: .degrees(90),
                        clockwise: false)
            path.closeSubpath()
            return path
        }
    }
}

/// Thin progress bar for language coverage.
public struct CoverageBar: View {
    let coverage: Coverage
    var height: CGFloat = 4

    public init(_ coverage: Coverage, height: CGFloat = 4) {
        self.coverage = coverage
        self.height = height
    }

    public var body: some View {
        GeometryReader { geometry in
            let total = max(coverage.total, 1)
            let width = geometry.size.width
            HStack(spacing: 0) {
                Rectangle().fill(RunaColor.approved).frame(width: width * CGFloat(coverage.approved) / CGFloat(total))
                Rectangle().fill(RunaColor.review).frame(width: width * CGFloat(coverage.needsReview) / CGFloat(total))
                Rectangle().fill(RunaColor.machine).frame(width: width * CGFloat(coverage.machine) / CGFloat(total))
                Spacer(minLength: 0)
            }
            .background(RunaColor.borderStrong)
            .clipShape(Capsule())
        }
        .frame(height: height)
        .accessibilityLabel("\(Int(coverage.translatedFraction * 100)) percent translated")
    }
}

// MARK: Chips and keys

public struct Chip: View {
    let text: String
    let systemImage: String?
    let tint: Color?

    public init(_ text: String, systemImage: String? = nil, tint: Color? = nil) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 9.5, weight: .semibold)) }
            Text(text).font(RunaFont.mini)
        }
        .foregroundStyle(tint ?? RunaColor.textSecondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(RoundedRectangle(cornerRadius: RunaRadius.chip).fill((tint ?? RunaColor.textTertiary).opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: RunaRadius.chip).strokeBorder(RunaColor.borderSubtle))
    }
}

/// A keyboard shortcut hint, like ⌘K.
public struct KeyCap: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(RunaFont.font(size: 10.5, weight: .medium))
            .foregroundStyle(RunaColor.textTertiary)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 16)
            .background(RoundedRectangle(cornerRadius: 3).fill(RunaColor.hover))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(RunaColor.borderSubtle))
    }
}

// MARK: Buttons

public struct RunaButtonStyle: ButtonStyle {
    public enum Kind: Sendable { case primary, secondary, ghost, destructive }
    public enum Size: Sendable { case small, regular, large }

    let kind: Kind
    let size: Size
    @Environment(\.isEnabled) private var isEnabled

    public init(_ kind: Kind = .secondary, size: Size = .regular) {
        self.kind = kind
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        HoverReader { hovering in
            configuration.label
                .font(size == .small ? RunaFont.smallMedium : RunaFont.bodyMedium)
                .lineLimit(1)
                .padding(.horizontal, size == .small ? 8 : size == .large ? 16 : 12)
                .frame(height: size == .small ? 24 : size == .large ? 36 : 30)
                .foregroundStyle(foreground)
                .background(RoundedRectangle(cornerRadius: RunaRadius.control).fill(background(hovering: hovering, pressed: configuration.isPressed)))
                .overlay(RoundedRectangle(cornerRadius: RunaRadius.control).strokeBorder(border))
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: RunaRadius.control))
                .animation(RunaMotion.quick, value: hovering)
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: RunaColor.onAccent
        case .secondary: RunaColor.textPrimary
        case .ghost: RunaColor.textSecondary
        case .destructive: RunaColor.missing
        }
    }

    private func background(hovering: Bool, pressed: Bool) -> Color {
        switch kind {
        case .primary: pressed ? RunaColor.accent.opacity(0.85) : hovering ? RunaColor.accentHover : RunaColor.accent
        case .secondary: pressed ? RunaColor.borderStrong : hovering ? RunaColor.hover : RunaColor.elevated
        case .ghost: pressed ? RunaColor.borderStrong : hovering ? RunaColor.hover : .clear
        case .destructive: hovering ? RunaColor.missing.opacity(0.14) : RunaColor.missing.opacity(0.08)
        }
    }

    private var border: Color {
        switch kind {
        case .primary: .clear
        case .secondary: RunaColor.borderStrong
        case .ghost: .clear
        case .destructive: RunaColor.missing.opacity(0.25)
        }
    }
}

extension ButtonStyle where Self == RunaButtonStyle {
    public static var runaPrimary: RunaButtonStyle { RunaButtonStyle(.primary) }
    public static var runaSecondary: RunaButtonStyle { RunaButtonStyle(.secondary) }
    public static var runaGhost: RunaButtonStyle { RunaButtonStyle(.ghost) }
    public static func runa(_ kind: RunaButtonStyle.Kind, size: RunaButtonStyle.Size = .regular) -> RunaButtonStyle {
        RunaButtonStyle(kind, size: size)
    }
}

/// Exposes hover state to a view builder.
public struct HoverReader<Content: View>: View {
    @State private var hovering = false
    let content: (Bool) -> Content

    public init(@ViewBuilder content: @escaping (Bool) -> Content) {
        self.content = content
    }

    public var body: some View {
        content(hovering).onHover { hovering = $0 }
    }
}

// MARK: Fields

public struct RunaFieldStyle: TextFieldStyle {
    @FocusState private var focused: Bool
    let monospaced: Bool

    public init(monospaced: Bool = false) {
        self.monospaced = monospaced
    }

    public func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(monospaced ? RunaFont.keyName : RunaFont.body)
            .foregroundStyle(RunaColor.textPrimary)
            .focused($focused)
            .padding(.horizontal, 9)
            .frame(minHeight: 30)
            .background(RoundedRectangle(cornerRadius: RunaRadius.control).fill(RunaColor.panel))
            .overlay(RoundedRectangle(cornerRadius: RunaRadius.control)
                .strokeBorder(focused ? RunaColor.accent.opacity(0.8) : RunaColor.borderStrong, lineWidth: focused ? 1.5 : 1))
            .animation(RunaMotion.quick, value: focused)
    }
}

extension TextFieldStyle where Self == RunaFieldStyle {
    public static var runa: RunaFieldStyle { RunaFieldStyle() }
    public static var runaMono: RunaFieldStyle { RunaFieldStyle(monospaced: true) }
}

/// A multi-line editor that grows with its content, styled like `RunaFieldStyle`.
public struct RunaTextEditor: View {
    @Binding var text: String
    let placeholder: String
    let isRightToLeft: Bool
    var onCommit: (() -> Void)?
    @FocusState private var focused: Bool

    public init(_ placeholder: String, text: Binding<String>, isRightToLeft: Bool = false, onCommit: (() -> Void)? = nil) {
        self.placeholder = placeholder
        self._text = text
        self.isRightToLeft = isRightToLeft
        self.onCommit = onCommit
    }

    public var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(RunaFont.body)
            .lineLimit(1...12)
            .foregroundStyle(RunaColor.textPrimary)
            .multilineTextAlignment(isRightToLeft ? .trailing : .leading)
            .environment(\.layoutDirection, isRightToLeft ? .rightToLeft : .leftToRight)
            .focused($focused)
            .onSubmit { onCommit?() }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: RunaRadius.control).fill(RunaColor.panel))
            .overlay(RoundedRectangle(cornerRadius: RunaRadius.control)
                .strokeBorder(focused ? RunaColor.accent.opacity(0.8) : RunaColor.borderSubtle, lineWidth: focused ? 1.5 : 1))
            .onChange(of: focused) { _, isFocused in
                if !isFocused { onCommit?() }
            }
    }
}

// MARK: Surfaces

public struct Card<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(RunaSpacing.m)
            .background(RoundedRectangle(cornerRadius: RunaRadius.card).fill(RunaColor.elevated))
            .overlay(RoundedRectangle(cornerRadius: RunaRadius.card).strokeBorder(RunaColor.borderSubtle))
    }
}

public struct SectionLabel: View {
    let text: String
    let trailing: AnyView?

    public init(_ text: String) {
        self.text = text
        self.trailing = nil
    }

    public init<Trailing: View>(_ text: String, @ViewBuilder trailing: () -> Trailing) {
        self.text = text
        self.trailing = AnyView(trailing())
    }

    public var body: some View {
        HStack {
            Text(text).font(RunaFont.smallMedium).foregroundStyle(RunaColor.textTertiary)
            Spacer()
            trailing
        }
    }
}

public struct Banner<Actions: View>: View {
    public enum Tone: Sendable { case info, warning, danger, success }
    let tone: Tone
    let title: String
    let message: String?
    let actions: Actions

    public init(_ tone: Tone, title: String, message: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.tone = tone
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var color: Color {
        switch tone {
        case .info: RunaColor.accent
        case .warning: RunaColor.review
        case .danger: RunaColor.missing
        case .success: RunaColor.approved
        }
    }

    var icon: String {
        switch tone {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .danger: "xmark.octagon.fill"
        case .success: "checkmark.circle.fill"
        }
    }

    public var body: some View {
        HStack(alignment: .center, spacing: RunaSpacing.s) {
            Image(systemName: icon).foregroundStyle(color).font(.system(size: 12))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(RunaFont.bodyMedium).foregroundStyle(RunaColor.textPrimary)
                if let message { Text(message).font(RunaFont.small).foregroundStyle(RunaColor.textTertiary) }
            }
            Spacer(minLength: RunaSpacing.s)
            actions
        }
        .padding(.horizontal, RunaSpacing.m)
        .padding(.vertical, RunaSpacing.s)
        .background(RoundedRectangle(cornerRadius: RunaRadius.card).fill(color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: RunaRadius.card).strokeBorder(color.opacity(0.22)))
    }
}

public struct EmptyStateView<Actions: View>: View {
    let systemImage: String
    let title: String
    let message: String
    let actions: Actions

    public init(systemImage: String, title: String, message: String, @ViewBuilder actions: () -> Actions) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: RunaSpacing.m) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(RunaColor.textQuaternary)
            VStack(spacing: RunaSpacing.xs) {
                Text(title).font(RunaFont.title3).foregroundStyle(RunaColor.textPrimary)
                Text(message).font(RunaFont.body).foregroundStyle(RunaColor.textTertiary).multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            actions.padding(.top, RunaSpacing.xs)
        }
        .padding(RunaSpacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Initials in a circle, for people in history.
public struct Avatar: View {
    let name: String
    var size: CGFloat = 18

    public init(_ name: String, size: CGFloat = 18) {
        self.name = name
        self.size = size
    }

    public var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        let hue = Double(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
        Text(initials.isEmpty ? "?" : initials)
            .font(RunaFont.font(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Color(hue: hue, saturation: 0.45, brightness: 0.62)))
    }
}

public struct HairlineDivider: View {
    public init() {}
    public var body: some View {
        Rectangle().fill(RunaColor.borderSubtle).frame(height: 1)
    }
}

// MARK: Placeholder-aware text

/// Text with `{placeholders}` tinted, so variables stand out from copy.
public struct PlaceholderText: View {
    let text: String
    let font: Font
    let color: Color
    let placeholderColor: Color

    public init(_ text: String, font: Font = RunaFont.body, color: Color = RunaColor.textPrimary, placeholderColor: Color = RunaColor.accent) {
        self.text = text
        self.font = font
        self.color = color
        self.placeholderColor = placeholderColor
    }

    public var body: some View {
        Text(attributed).font(font)
    }

    var attributed: AttributedString {
        var result = AttributedString()
        for segment in CanonicalText.parse(text) {
            switch segment {
            case .literal(let literal):
                var part = AttributedString(literal)
                part.foregroundColor = color
                result += part
            case .placeholder(let placeholder):
                var part = AttributedString("{\(placeholder.name)}")
                part.foregroundColor = placeholderColor
                result += part
            }
        }
        return result
    }
}

/// A sidebar row with Linear's quiet hover and selection instead of the system highlight.
public struct SidebarRow<Leading: View, Trailing: View>: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    let leading: Leading
    let trailing: Trailing

    public init(_ title: String, isSelected: Bool, action: @escaping () -> Void, @ViewBuilder leading: () -> Leading,
                @ViewBuilder trailing: () -> Trailing)
    {
        self.title = title
        self.isSelected = isSelected
        self.action = action
        self.leading = leading()
        self.trailing = trailing()
    }

    public var body: some View {
        Button(action: action) {
            HoverReader { hovering in
                HStack(spacing: RunaSpacing.s) {
                    leading.frame(width: 18)
                    Text(title)
                        .font(isSelected ? RunaFont.bodyMedium : RunaFont.body)
                        .foregroundStyle(isSelected ? RunaColor.textPrimary : RunaColor.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    trailing
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: RunaRadius.control)
                    .fill(isSelected ? RunaColor.borderStrong : hovering ? RunaColor.hover : .clear))
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: Checkbox

/// A small square checkbox in Runa's accent, used instead of the system checkbox so it matches
/// the rest of the UI in light and dark.
public struct RunaCheckboxStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(configuration.isOn ? RunaColor.accent : RunaColor.panel)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(configuration.isOn ? RunaColor.accent : RunaColor.borderStrong, lineWidth: 1))
                    .overlay {
                        if configuration.isOn {
                            Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.white)
                        }
                    }
                    .frame(width: 14, height: 14)
                configuration.label
                    .foregroundStyle(RunaColor.textSecondary)
            }
            .contentShape(Rectangle())
            .animation(RunaMotion.quick, value: configuration.isOn)
        }
        .buttonStyle(.plain)
    }
}

extension ToggleStyle where Self == RunaCheckboxStyle {
    public static var runaCheckbox: RunaCheckboxStyle { RunaCheckboxStyle() }
}
