import AppKit
import ShelfDropCore
import SwiftUI

struct ShelfRootView: View {
    @ObservedObject var viewModel: ShelfViewModel
    @State private var renameShelfTitle = ""
    @State private var zipBaseName = "Shelf Bundle"
    @State private var pdfBaseName = "Combined Images"
    @State private var isDropTargeted = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.96, green: 0.93, blue: 0.87),
                    Color(red: 0.93, green: 0.96, blue: 0.98),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            HSplitView {
                SessionsSidebar(viewModel: viewModel, renameShelfTitle: $renameShelfTitle)
                    .frame(minWidth: 220, idealWidth: 250, maxWidth: 280)

                VStack(spacing: 0) {
                    HeaderBar(viewModel: viewModel)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)

                    Divider()

                    FileReviewBanner(viewModel: viewModel)
                        .padding(.horizontal, 18)
                        .padding(.top, 14)

                    DropShelfView(viewModel: viewModel, isDropTargeted: $isDropTargeted)
                        .padding(18)
                }
                .frame(minWidth: 620)
                .background(Color.white.opacity(0.55))

                InspectorPanel(
                    viewModel: viewModel,
                    zipBaseName: $zipBaseName,
                    pdfBaseName: $pdfBaseName
                )
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)
            }
        }
        .sheet(item: $viewModel.pendingPreview) { pending in
            ActionPreviewSheet(pending: pending)
        }
        .alert("Action Error", isPresented: Binding(get: {
            viewModel.errorMessage != nil
        }, set: { shouldShow in
            if !shouldShow {
                viewModel.errorMessage = nil
            }
        })) {
            Button("OK", role: .cancel) {
                viewModel.errorMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
        .overlay(alignment: .topTrailing) {
            if viewModel.isBusy {
                ProgressView("Working…")
                    .padding(12)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding()
            }
        }
    }
}

private struct HeaderBar: View {
    @ObservedObject var viewModel: ShelfViewModel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("ShelfDrop")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("Inbox triage for the messy pile you do not want to sort inside Finder.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            TextField("Search files, tags, or type", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)

            Button("Add Files…") {
                viewModel.addFiles(urls: FolderPicker.chooseFiles())
            }

            Button(viewModel.selectedSession.isPinned ? "Unpin" : "Pin Shelf") {
                viewModel.togglePinSelectedShelf()
            }

            Button("Undo Last Batch") {
                viewModel.performUndo()
            }
            .disabled(!viewModel.canUndo)
        }
    }
}

private struct SessionsSidebar: View {
    @ObservedObject var viewModel: ShelfViewModel
    @Binding var renameShelfTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Shelves")
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.createShelf()
                    renameShelfTitle = viewModel.selectedSession.title
                } label: {
                    Label("New Shelf", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }

            TextField("Shelf title", text: Binding(
                get: {
                    renameShelfTitle.isEmpty ? viewModel.selectedSession.title : renameShelfTitle
                },
                set: { renameShelfTitle = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .onSubmit {
                viewModel.renameSelectedShelf(renameShelfTitle)
            }

            if !viewModel.pinnedSessions.isEmpty {
                shelfSection(title: "Pinned", sessions: viewModel.pinnedSessions)
            }

            shelfSection(title: "Recent", sessions: viewModel.recentSessions)

            Spacer()

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Summon with Option-Space", systemImage: "keyboard")
                    Label("Preview with Space", systemImage: "eye")
                    Label("Drag out to file apps", systemImage: "arrow.up.right.square")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Shelf Tips")
            }
        }
        .padding(18)
        .background(Color.black.opacity(0.05))
        .onAppear {
            renameShelfTitle = viewModel.selectedSession.title
        }
        .onChange(of: viewModel.selectedSessionID) {
            renameShelfTitle = viewModel.selectedSession.title
        }
    }

    private func shelfSection(title: String, sessions: [ShelfSession]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(sessions) { session in
                Button {
                    viewModel.select(sessionID: session.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.title)
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                            Text("\(session.items.count) item\(session.items.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if session.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.caption)
                                .foregroundStyle(Color.orange)
                        }
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(session.id == viewModel.selectedSessionID ? Color.white.opacity(0.8) : Color.white.opacity(0.38))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct FileReviewBanner: View {
    @ObservedObject var viewModel: ShelfViewModel

    var body: some View {
        HStack(spacing: 14) {
            ReviewBadge(
                title: "Duplicates",
                value: "\(viewModel.review.duplicateGroups.count)",
                color: .orange
            )
            ReviewBadge(
                title: "Warnings",
                value: "\(viewModel.review.issues.filter { $0.severity == .warning }.count)",
                color: .yellow
            )
            ReviewBadge(
                title: "Blocking",
                value: "\(viewModel.review.issues.filter { $0.severity == .error }.count)",
                color: .red
            )
            Spacer()
            if !viewModel.selectedItemIDs.isEmpty {
                Text("\(viewModel.selectedItemIDs.count) selected")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ReviewBadge: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color.opacity(0.25))
                .frame(width: 12, height: 12)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
    }
}

private struct DropShelfView: View {
    @ObservedObject var viewModel: ShelfViewModel
    @Binding var isDropTargeted: Bool

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Current Shelf")
                    .font(.headline)
                Spacer()
                Button("Quick Look") {
                    viewModel.openQuickLook()
                }
                .disabled(viewModel.selectedItemIDs.isEmpty)

                SharingButton(urls: viewModel.selectedItems.map(\.url))
                    .frame(width: 70)

                Button("Reveal") {
                    viewModel.revealSelectedInFinder()
                }
                .disabled(viewModel.selectedItemIDs.isEmpty)

                Button("Copy Paths") {
                    viewModel.copySelectedPaths()
                }
                .disabled(viewModel.selectedItemIDs.isEmpty)

                Button("Remove from Shelf") {
                    viewModel.removeSelectedFromShelf()
                }
                .disabled(viewModel.selectedItemIDs.isEmpty)

                Button("Clear Shelf") {
                    viewModel.clearShelf()
                }
                .disabled(viewModel.selectedSession.items.isEmpty)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(isDropTargeted ? Color.orange.opacity(0.18) : Color.white.opacity(0.82))
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [10, 12]))
                    .foregroundStyle(isDropTargeted ? Color.orange : Color.secondary.opacity(0.35))

                if viewModel.visibleItems.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray.and.arrow.down.fill")
                            .font(.system(size: 42))
                            .foregroundStyle(.secondary)
                        Text("Drop files here to stage a review-first batch")
                            .font(.title3.weight(.semibold))
                        Text("Then rename, archive, tag, comment, zip, transform, or safely delete them.")
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                } else {
                    List(viewModel.visibleItems, selection: $viewModel.selectedItemIDs) { item in
                        ShelfItemRow(
                            item: item,
                            duplicateGroup: viewModel.review.duplicateGroups.first(where: { $0.itemIDs.contains(item.id) }),
                            issues: viewModel.review.issues.filter { $0.itemID == item.id }
                        )
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                    .scrollContentBackground(.hidden)
                    .listStyle(.plain)
                    .padding(8)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                viewModel.addFiles(urls: urls)
                return true
            } isTargeted: { targeted in
                isDropTargeted = targeted
            }
        }
    }
}

private struct ShelfItemRow: View {
    let item: ShelfItem
    let duplicateGroup: DuplicateGroup?
    let issues: [PreflightIssue]

    var body: some View {
        HStack(spacing: 14) {
            ThumbnailView(url: item.url)
                .frame(width: 70, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.displayName)
                        .font(.body.weight(.medium))
                    if duplicateGroup != nil {
                        Capsule()
                            .fill(Color.orange.opacity(0.16))
                            .overlay(
                                Text("Duplicate")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.orange)
                                    .padding(.horizontal, 8)
                            )
                            .frame(height: 22)
                    }
                }
                Text(item.kindDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(ByteCountFormatter.string(fromByteCount: item.byteSize, countStyle: .file))
                    if item.isLocked {
                        Label("Locked", systemImage: "lock.fill")
                    }
                    if item.isAlias {
                        Label("Alias", systemImage: "arrow.turn.down.right")
                    }
                    if item.isUbiquitous {
                        Label("iCloud", systemImage: "icloud")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if !issues.isEmpty {
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(issues.prefix(2)) { issue in
                        Text(issue.message)
                            .font(.caption2)
                            .foregroundStyle(issue.severity == .error ? Color.red : Color.orange)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 240, alignment: .trailing)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.82))
        )
    }
}

private struct InspectorPanel: View {
    @ObservedObject var viewModel: ShelfViewModel
    @Binding var zipBaseName: String
    @Binding var pdfBaseName: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                inspectorHeader
                previewSection
                filingSection
                renameSection
                metadataSection
                transformSection
                issuesSection
            }
            .padding(18)
        }
        .background(Color.white.opacity(0.75))
    }

    private var inspectorHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Inspector")
                .font(.headline)
            Text(viewModel.selectedItemIDs.isEmpty ? "Pick files to review actions." : "\(viewModel.selectedItemIDs.count) file\(viewModel.selectedItemIDs.count == 1 ? "" : "s") selected")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var previewSection: some View {
        GroupBox("Preview") {
            if let item = viewModel.selectedItems.first {
                VStack(alignment: .leading, spacing: 12) {
                    ThumbnailView(url: item.url)
                        .frame(height: 160)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    Text(item.displayName)
                        .font(.headline)
                    Text(item.url.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if !item.tags.isEmpty {
                        Text(item.tags.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Select a file to inspect its thumbnail, tags, and path.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var filingSection: some View {
        GroupBox("File and Archive") {
            VStack(alignment: .leading, spacing: 10) {
                actionButton("Move to Folder…", enabled: !viewModel.selectedItemIDs.isEmpty) {
                    if let destination = FolderPicker.chooseFolder(title: "Move Selected Files") {
                        viewModel.previewMove(destination: destination, mode: .move)
                    }
                }
                actionButton("Copy to Folder…", enabled: !viewModel.selectedItemIDs.isEmpty) {
                    if let destination = FolderPicker.chooseFolder(title: "Copy Selected Files") {
                        viewModel.previewMove(destination: destination, mode: .copy)
                    }
                }
                Picker("Archive Strategy", selection: $viewModel.archiveStrategy) {
                    ForEach(ArchiveStrategy.allCases) { strategy in
                        Text(strategy.displayName).tag(strategy)
                    }
                }
                .labelsHidden()

                actionButton("Archive to Root…", enabled: !viewModel.selectedItemIDs.isEmpty) {
                    if let destination = FolderPicker.chooseFolder(title: "Choose Archive Root") {
                        viewModel.previewArchive(root: destination)
                    }
                }

                actionButton("Safe Delete", enabled: !viewModel.selectedItemIDs.isEmpty) {
                    viewModel.previewSafeDelete()
                }

                if !viewModel.recentDestinations.isEmpty {
                    Divider()
                    Text("Recent destinations")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(viewModel.recentDestinations, id: \.self) { url in
                        Button(url.lastPathComponent) {
                            viewModel.previewMove(destination: url, mode: .move)
                        }
                        .disabled(viewModel.selectedItemIDs.isEmpty)
                    }
                }
            }
        }
    }

    private var renameSection: some View {
        GroupBox("Rename Cleanup") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Prefixes to strip", text: Binding(
                    get: { viewModel.renamePattern.prefixesToRemove.joined(separator: ", ") },
                    set: { newValue in
                        viewModel.renamePattern.prefixesToRemove = newValue
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                    }
                ))
                .textFieldStyle(.roundedBorder)

                HStack {
                    Picker("Separator", selection: $viewModel.renamePattern.separator) {
                        ForEach(RenameSeparator.allCases) { separator in
                            Text(separator.displayName).tag(separator)
                        }
                    }
                    Picker("Case", selection: $viewModel.renamePattern.caseStyle) {
                        ForEach(RenameCaseStyle.allCases) { style in
                            Text(style.rawValue.capitalized).tag(style)
                        }
                    }
                }
                HStack {
                    Picker("Date", selection: $viewModel.renamePattern.dateSource) {
                        ForEach(RenameDateSource.allCases) { source in
                            Text(source.rawValue.capitalized).tag(source)
                        }
                    }
                    Toggle("Counter", isOn: $viewModel.renamePattern.includeCounter)
                }
                TextField("Prefix", text: $viewModel.renamePattern.customPrefix)
                    .textFieldStyle(.roundedBorder)
                TextField("Suffix", text: $viewModel.renamePattern.customSuffix)
                    .textFieldStyle(.roundedBorder)

                actionButton("Preview Rename", enabled: !viewModel.selectedItemIDs.isEmpty) {
                    viewModel.previewRename()
                }
            }
        }
    }

    private var metadataSection: some View {
        GroupBox("Finder Metadata") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Tags (comma separated)", text: Binding(
                    get: { viewModel.metadataRequest.tags.joined(separator: ", ") },
                    set: { value in
                        viewModel.metadataRequest.tags = value
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                    }
                ))
                .textFieldStyle(.roundedBorder)

                Picker("Finder Label", selection: $viewModel.metadataRequest.label) {
                    ForEach(FinderLabelColor.allCases) { label in
                        Text(label.displayName).tag(label)
                    }
                }

                TextField("Finder Comment", text: Binding(
                    get: { viewModel.metadataRequest.comment ?? "" },
                    set: { viewModel.metadataRequest.comment = $0 }
                ), axis: .vertical)
                .lineLimit(3...5)
                .textFieldStyle(.roundedBorder)

                actionButton("Preview Metadata", enabled: !viewModel.selectedItemIDs.isEmpty) {
                    viewModel.previewMetadata()
                }
            }
        }
    }

    private var transformSection: some View {
        GroupBox("Small Batch Transforms") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("ZIP name", text: $zipBaseName)
                    .textFieldStyle(.roundedBorder)
                actionButton("Create ZIP…", enabled: !viewModel.selectedItemIDs.isEmpty) {
                    if let destination = FolderPicker.chooseFolder(title: "Choose ZIP Destination") {
                        viewModel.previewZip(destination: destination, baseName: zipBaseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Shelf Bundle" : zipBaseName)
                    }
                }

                Divider()

                Picker("Image Format", selection: $viewModel.imageTransformPlan.outputFormat) {
                    ForEach(ImageOutputFormat.allCases) { format in
                        Text(format.rawValue.uppercased()).tag(format)
                    }
                }
                Toggle("Strip metadata", isOn: $viewModel.imageTransformPlan.stripMetadata)
                HStack {
                    Text("Max size")
                    Spacer()
                    TextField(
                        "2048",
                        value: Binding(
                            get: { viewModel.imageTransformPlan.maxPixelSize ?? 2048 },
                            set: { viewModel.imageTransformPlan.maxPixelSize = $0 }
                        ),
                        format: .number
                    )
                    .frame(width: 90)
                }

                actionButton("Convert Images…", enabled: viewModel.selectedItems.contains(where: \.isImage)) {
                    if let destination = FolderPicker.chooseFolder(title: "Choose Image Output Folder") {
                        viewModel.previewImageTransform(destination: destination)
                    }
                }

                TextField("PDF name", text: $pdfBaseName)
                    .textFieldStyle(.roundedBorder)
                actionButton("Create PDF from Images…", enabled: viewModel.selectedItems.contains(where: \.isImage)) {
                    if let destination = FolderPicker.chooseFolder(title: "Choose PDF Destination") {
                        viewModel.previewCreatePDF(destination: destination, baseName: pdfBaseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Combined Images" : pdfBaseName)
                    }
                }
            }
        }
    }

    private var issuesSection: some View {
        GroupBox("Trust Checks") {
            VStack(alignment: .leading, spacing: 10) {
                if viewModel.review.duplicateGroups.isEmpty && viewModel.review.issues.isEmpty {
                    Text("No issues detected on the current shelf.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.review.duplicateGroups) { group in
                        Text("Exact duplicate group: \(group.itemIDs.count) files, \(ByteCountFormatter.string(fromByteCount: group.byteSize, countStyle: .file)) each")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(viewModel.review.issues) { issue in
                        Text(issue.message)
                            .font(.caption)
                            .foregroundStyle(issue.severity == .error ? Color.red : Color.orange)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func actionButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .disabled(!enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
