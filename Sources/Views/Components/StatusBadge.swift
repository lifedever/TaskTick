import SwiftUI
import TaskTickCore

extension ExecutionStatus {
    /// Semantic colour for this status, shared by every place that renders
    /// execution state (StatusBadge, sidebar row indicator, …).
    var color: Color {
        switch self {
        case .running: .blue
        case .success: .green
        case .failure: .red
        case .timeout: .orange
        case .cancelled: .gray
        }
    }
}

/// A small badge displaying execution status with color and icon.
struct StatusBadge: View {
    let status: ExecutionStatus
    var compact: Bool = false

    var color: Color { status.color }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.iconName)
                .font(.caption2)
            if !compact {
                Text(status.displayName)
                    .font(.caption)
                    .fontWeight(.medium)
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.1), in: Capsule())
    }
}
