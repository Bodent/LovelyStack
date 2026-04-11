import ShelfDropCore
import SwiftUI

struct ActionPreviewSheet: View {
    let pending: PendingPreview
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(pending.preview.title)
                        .font(.title2.weight(.bold))
                    Text(pending.preview.hasBlockingIssues ? "Resolve blocking issues before executing." : "Dry run complete. Review the proposed changes below.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if !pending.preview.issues.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Issues")
                        .font(.headline)
                    ForEach(pending.preview.issues) { issue in
                        Text(issue.message)
                            .font(.callout)
                            .foregroundStyle(issue.severity == .error ? Color.red : Color.orange)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Planned changes")
                    .font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(pending.preview.changes) { change in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(change.summary)
                                    .font(.body.weight(.medium))
                                Text(change.sourceURL.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                if let destination = change.destinationURL {
                                    Text(destination.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
                        }
                    }
                }
            }

            HStack {
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                Spacer()
                Button("Run Batch") {
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .disabled(pending.preview.hasBlockingIssues)
            }
        }
        .padding(24)
        .frame(width: 760, height: 580)
        .background(.regularMaterial)
    }
}
