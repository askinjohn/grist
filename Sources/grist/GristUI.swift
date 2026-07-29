import SwiftUI
import AppKit

// MARK: - Shared sheet chrome (consistent with New Task polish)

enum GristSheetTint {
    case accent
    case purple
    case blue
    case orange
    case red
    case green

    var color: Color {
        switch self {
        case .accent: return Color.accentColor
        case .purple: return .purple
        case .blue: return .blue
        case .orange: return .orange
        case .red: return .red
        case .green: return .green
        }
    }
}

/// Icon badge used in sheet headers and empty states.
struct GristIconBadge: View {
    let systemName: String
    var tint: GristSheetTint = .accent
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(tint.color.opacity(0.14))
                .frame(width: size, height: size)
            Image(systemName: systemName)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(tint.color)
        }
    }
}

/// Sheet top bar: badge + title + subtitle + close.
struct GristSheetHeader: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String = "doc.text"
    var tint: GristSheetTint = .accent
    var onClose: (() -> Void)?
    var closeDisabled: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            GristIconBadge(systemName: systemImage, tint: tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .disabled(closeDisabled)
                .help("Close")
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }
}

/// Bottom Cancel + primary action row.
struct GristSheetFooter<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                leading()
                Spacer()
                trailing()
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
        }
    }
}

extension GristSheetFooter where Leading == EmptyView {
    init(@ViewBuilder trailing: @escaping () -> Trailing) {
        self.leading = { EmptyView() }
        self.trailing = trailing
    }
}

/// Labeled field chrome matching New Task.
struct GristLabeledField<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

struct GristFieldBackground: ViewModifier {
    var minHeight: CGFloat? = nil

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: minHeight, alignment: .topLeading)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

extension View {
    func gristFieldStyle(minHeight: CGFloat? = nil) -> some View {
        modifier(GristFieldBackground(minHeight: minHeight))
    }
}

/// Card used for empty states and choice rows.
struct GristInfoCard<Content: View>: View {
    var tint: GristSheetTint = .accent
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.color.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Centered empty-state block (detail pane, lists).
struct GristEmptyState: View {
    let systemImage: String
    let title: String
    var message: String? = nil
    var tint: GristSheetTint = .accent
    var badgeSize: CGFloat = 72

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(tint.color.opacity(0.12))
                    .frame(width: badgeSize, height: badgeSize)
                Image(systemName: systemImage)
                    .font(.system(size: badgeSize * 0.42, weight: .light))
                    .foregroundStyle(tint.color)
            }
            VStack(spacing: 6) {
                Text(title)
                    .font(.title2.weight(.semibold))
                if let message, !message.isEmpty {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
            }
        }
    }
}
