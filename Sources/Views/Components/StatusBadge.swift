import SwiftUI
import TaskTickCore

/// Semantic colour used across the app for a given execution status. Centralised
/// here so the sidebar status icon, the "最近执行" list and `StatusBadge` all
/// stay visually consistent.
extension ExecutionStatus {
    var statusColor: Color {
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

    var color: Color {
        status.statusColor
    }

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
