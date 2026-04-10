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
        NavigationSplitView {
            SessionsSidebar(viewModel: viewModel, renameShelfTitle: $renameShelfTitle)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 300)
        } content: {
            VStack(spacing: 0) {
                FileReviewBanner(viewModel: viewModel)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                Divider()

                DropShelfView(viewModel: viewModel, isDropTargeted: $isDropTargeted)
            }
            .navigationSplitViewColumnWidth(min: 400, ideal: 600)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        viewModel.addFiles(urls: FolderPicker.chooseFiles())
                    } label: {
                        Label("Add Files", systemImage: "doc.badge.plus")
                    }
                    .help("Add Files")

                    Button {
                        viewModel.togglePinSelectedShelf()
                    } label: {
                        Label(viewModel.selectedSession.isPinned ? "Unpin Shelf" : "Pin Shelf", systemImage: viewModel.selectedSession.isPinned ? "pin.slash" : "pin")
                    }
                    .help(viewModel.selectedSession.isPinned ? "Unpin Shelf" : "Pin Shelf")

                    Button {
                        viewModel.performUndo()
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!viewModel.canUndo)
                    .help("Undo Last Batch")
                }
            }
            .searchable(text: $viewModel.searchText, prompt: "Search files, tags, or type")
        } detail: {
            InspectorPanel(
                viewModel: viewModel,
                zipBaseName: $zipBaseName,
                pdfBaseName: $pdfBaseName
            )
            .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 450)
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

private struct SessionsSidebar: View {
    @ObservedObject var viewModel: ShelfViewModel
    @Binding var renameShelfTitle: String

    var body: some View {
        List(selection: Binding(
            get: { viewModel.selectedSessionID },
            set: { newID in if let id = newID { viewModel.select(sessionID: id) } }
        )) {
            if !viewModel.pinnedSessions.isEmpty {
                Section("Pinned") {
                    ForEach(viewModel.pinnedSessions) { session in
                        SidebarRow(session: session)
                            .tag(session.id)
                    }
                }
            }

            Section("Recent") {
                ForEach(viewModel.recentSessions) { session in
                    SidebarRow(session: session)
                        .tag(session.id)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
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

                Button {
                    viewModel.createShelf()
                    renameShelfTitle = viewModel.selectedSession.title
                } label: {
                    Label("New Shelf", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(.bar)
        }
        .onAppear {
            renameShelfTitle = viewModel.selectedSession.title
        }
        .onChange(of: viewModel.selectedSessionID) {
            renameShelfTitle = viewModel.selectedSession.title
        }
    }
}

private struct SidebarRow: View {
    let session: ShelfSession
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .lineLimit(1)
                Text("\(session.items.count) item\(session.items.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if session.isPinned {
                Image(systemName: "pin.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct FileReviewBanner: View {
    @ObservedObject var viewModel: ShelfViewModel

    var body: some View {
        HStack(spacing: 16) {
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
                    .font(.subheadline)
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
        HStack(spacing: 6) {
            Image(systemName: "circle.fill")
                .foregroundStyle(color)
                .font(.system(size: 8))
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
                .fontWeight(.medium)
        }
        .font(.subheadline)
    }
}

private struct DropShelfView: View {
    @ObservedObject var viewModel: ShelfViewModel
    @Binding var isDropTargeted: Bool

    var body: some View {
        ZStack {
            if viewModel.visibleItems.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text("Drop files here to stage a review-first batch")
                        .font(.title3.weight(.medium))
                    Text("Then rename, archive, tag, comment, zip, transform, or safely delete them.")
                        .foregroundStyle(.secondary)
                }
                .padding()
            } else {
                List(selection: $viewModel.selectedItemIDs) {
                    ForEach(viewModel.visibleItems) { item in
                        ShelfItemRow(
                            item: item,
                            duplicateGroup: viewModel.review.duplicateGroups.first(where: { $0.itemIDs.contains(item.id) }),
                            issues: viewModel.review.issues.filter { $0.itemID == item.id }
                        )
                        .tag(item.id)
                        .contextMenu {
                            Button("Quick Look") {
                                viewModel.openQuickLook()
                            }
                            Button("Reveal in Finder") {
                                viewModel.revealSelectedInFinder()
                            }
                            Button("Copy Paths") {
                                viewModel.copySelectedPaths()
                            }
                            Divider()
                            Button("Remove from Shelf", role: .destructive) {
                                viewModel.removeSelectedFromShelf()
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds()
            }

            if isDropTargeted {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay {
                        VStack(spacing: 12) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 48))
                                .foregroundStyle(Color.accentColor)
                            Text("Drop to Add Files")
                                .font(.title2.weight(.medium))
                        }
                    }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            viewModel.addFiles(urls: urls)
            return true
        } isTargeted: { targeted in
            withAnimation(.easeInOut(duration: 0.2)) {
                isDropTargeted = targeted
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !viewModel.visibleItems.isEmpty {
                HStack {
                    Button("Quick Look") { viewModel.openQuickLook() }
                        .disabled(viewModel.selectedItemIDs.isEmpty)
                    SharingButton(urls: viewModel.selectedItems.map(\.url))
                        .frame(width: 60)
                    Spacer()
                    Button("Clear Shelf", role: .destructive) {
                        viewModel.clearShelf()
                    }
                }
                .padding()
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
            }
        }
    }
}

private struct ShelfItemRow: View {
    let item: ShelfItem
    let duplicateGroup: DuplicateGroup?
    let issues: [PreflightIssue]

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailView(url: item.url)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.displayName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if duplicateGroup != nil {
                        Text("Duplicate")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(Color.orange)
                    }
                }

                HStack(spacing: 8) {
                    Text(item.kindDescription)
                    Text("•")
                        .foregroundStyle(.tertiary)
                    Text(ByteCountFormatter.string(fromByteCount: item.byteSize, countStyle: .file))

                    if item.isLocked || item.isAlias || item.isUbiquitous {
                        Text("•")
                            .foregroundStyle(.tertiary)
                        HStack(spacing: 4) {
                            if item.isLocked { Image(systemName: "lock.fill") }
                            if item.isAlias { Image(systemName: "arrow.turn.down.right") }
                            if item.isUbiquitous { Image(systemName: "icloud") }
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            if !issues.isEmpty {
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(issues.prefix(2)) { issue in
                        Label(issue.message, systemImage: issue.severity == .error ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(issue.severity == .error ? Color.red : Color.orange)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct InspectorPanel: View {
    @ObservedObject var viewModel: ShelfViewModel
    @Binding var zipBaseName: String
    @Binding var pdfBaseName: String

    @AppStorage("inspector.expanded.preview") private var isPreviewExpanded = true
    @AppStorage("inspector.expanded.filing") private var isFilingExpanded = true
    @AppStorage("inspector.expanded.rename") private var isRenameExpanded = false
    @AppStorage("inspector.expanded.metadata") private var isMetadataExpanded = false
    @AppStorage("inspector.expanded.transforms") private var isTransformsExpanded = false
    @AppStorage("inspector.expanded.issues") private var isIssuesExpanded = true

    var body: some View {
        Form {
            DisclosureGroup(isExpanded: $isPreviewExpanded) {
                previewContent
            } label: {
                Text("Preview")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup(isExpanded: $isFilingExpanded) {
                filingContent
            } label: {
                Text("File & Archive")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup(isExpanded: $isRenameExpanded) {
                renameContent
            } label: {
                Text("Rename Cleanup")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup(isExpanded: $isMetadataExpanded) {
                metadataContent
            } label: {
                Text("Finder Metadata")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup(isExpanded: $isTransformsExpanded) {
                transformsContent
            } label: {
                Text("Batch Transforms")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup(isExpanded: $isIssuesExpanded) {
                issuesContent
            } label: {
                Text("Trust Checks")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var previewContent: some View {
        Group {
            if let item = viewModel.selectedItems.first {
                VStack(alignment: .center, spacing: 12) {
                    ThumbnailView(url: item.url)
                        .frame(height: 160)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.displayName)
                            .font(.headline)
                        Text(item.url.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(3)

                        if !item.tags.isEmpty {
                            Text(item.tags.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 8)
            } else {
                Text("Select a file to inspect.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            }
        }
    }

    private var filingContent: some View {
        Group {
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

            inspectorLabeledRow("Archive Strategy") {
                Picker("Archive Strategy", selection: $viewModel.archiveStrategy) {
                    ForEach(ArchiveStrategy.allCases) { strategy in
                        Text(strategy.displayName).tag(strategy)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            actionButton("Archive to Root…", enabled: !viewModel.selectedItemIDs.isEmpty) {
                if let destination = FolderPicker.chooseFolder(title: "Choose Archive Root") {
                    viewModel.previewArchive(root: destination)
                }
            }

            actionButton("Safe Delete", enabled: !viewModel.selectedItemIDs.isEmpty) {
                viewModel.previewSafeDelete()
            }

            if !viewModel.recentDestinations.isEmpty {
                Section("Recent Destinations") {
                    ForEach(viewModel.recentDestinations, id: \.self) { url in
                        Button(url.lastPathComponent) {
                            viewModel.previewMove(destination: url, mode: .move)
                        }
                        .disabled(viewModel.selectedItemIDs.isEmpty)
                        .buttonStyle(.link)
                    }
                }
            }
        }
    }

    private var renameContent: some View {
        Group {
            inspectorLabeledRow("Strip prefixes\n(comma sep.)") {
                TextField("", text: Binding(
                    get: { viewModel.renamePattern.prefixesToRemove.joined(separator: ", ") },
                    set: { newValue in
                        viewModel.renamePattern.prefixesToRemove = newValue
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                    }
                ), prompt: Text("IMG_, DSC_, Screenshot"))
            }

            inspectorLabeledRow("Remove text") {
                TextField("", text: Binding(
                    get: { viewModel.renamePattern.textToRemove.joined(separator: ", ") },
                    set: { newValue in
                        viewModel.renamePattern.textToRemove = newValue
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                    }
                ))
            }

            inspectorLabeledRow("Separator") {
                Picker("Separator", selection: $viewModel.renamePattern.separator) {
                    ForEach(RenameSeparator.allCases) { separator in
                        Text(separator.displayName).tag(separator)
                    }
                }
                .labelsHidden()
            }

            inspectorLabeledRow("Case Style") {
                Picker("Case Style", selection: $viewModel.renamePattern.caseStyle) {
                    ForEach(RenameCaseStyle.allCases) { style in
                        Text(style.rawValue.capitalized).tag(style)
                    }
                }
                .labelsHidden()
            }

            inspectorLabeledRow("Append Date") {
                Picker("Append Date", selection: $viewModel.renamePattern.dateSource) {
                    ForEach(RenameDateSource.allCases) { source in
                        Text(source.rawValue.capitalized).tag(source)
                    }
                }
                .labelsHidden()
            }

            inspectorLabeledRow("Include Counter") {
                Toggle("Include Counter", isOn: $viewModel.renamePattern.includeCounter)
                    .labelsHidden()
            }

            inspectorLabeledRow("Custom Prefix") {
                TextField("", text: $viewModel.renamePattern.customPrefix)
            }
            inspectorLabeledRow("Custom Suffix") {
                TextField("", text: $viewModel.renamePattern.customSuffix)
            }

            actionButton("Preview Rename", enabled: !viewModel.selectedItemIDs.isEmpty) {
                viewModel.previewRename()
            }
        }
    }

    private var metadataContent: some View {
        Group {
            inspectorLabeledRow("Tags (comma sep.)") {
                TextField("", text: Binding(
                    get: { viewModel.metadataRequest.tags.joined(separator: ", ") },
                    set: { value in
                        viewModel.metadataRequest.tags = value
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                    }
                ))
            }

            inspectorLabeledRow("Finder Label") {
                Picker("Finder Label", selection: $viewModel.metadataRequest.label) {
                    ForEach(FinderLabelColor.allCases) { label in
                        Text(label.displayName).tag(label)
                    }
                }
                .labelsHidden()
            }

            inspectorLabeledRow("Finder Comment") {
                TextField("", text: Binding(
                    get: { viewModel.metadataRequest.comment ?? "" },
                    set: { viewModel.metadataRequest.comment = $0 }
                ), axis: .vertical)
                .lineLimit(3...5)
            }

            actionButton("Preview Metadata", enabled: !viewModel.selectedItemIDs.isEmpty) {
                viewModel.previewMetadata()
            }
        }
    }

    private var transformsContent: some View {
        Group {
            inspectorLabeledRow("ZIP Name") {
                TextField("", text: $zipBaseName)
            }
            actionButton("Create ZIP…", enabled: !viewModel.selectedItemIDs.isEmpty) {
                if let destination = FolderPicker.chooseFolder(title: "Choose ZIP Destination") {
                    viewModel.previewZip(destination: destination, baseName: zipBaseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Shelf Bundle" : zipBaseName)
                }
            }

            Divider()

            inspectorLabeledRow("Image Output") {
                Picker("Image Output", selection: $viewModel.imageTransformPlan.outputFormat) {
                    ForEach(ImageOutputFormat.allCases) { format in
                        Text(format.rawValue.uppercased()).tag(format)
                    }
                }
                .labelsHidden()
            }

            inspectorLabeledRow("Strip Metadata") {
                Toggle("Strip Metadata", isOn: $viewModel.imageTransformPlan.stripMetadata)
                    .labelsHidden()
            }

            inspectorLabeledRow("Max Size (px)") {
                TextField(
                    "",
                    value: Binding(
                        get: { viewModel.imageTransformPlan.maxPixelSize ?? 2048 },
                        set: { viewModel.imageTransformPlan.maxPixelSize = $0 }
                    ),
                    format: .number
                )
            }

            actionButton("Convert Images…", enabled: viewModel.selectedItems.contains(where: \.isImage)) {
                if let destination = FolderPicker.chooseFolder(title: "Choose Image Output Folder") {
                    viewModel.previewImageTransform(destination: destination)
                }
            }

            Divider()

            inspectorLabeledRow("PDF Name") {
                TextField("", text: $pdfBaseName)
            }
            actionButton("Create PDF from Images…", enabled: viewModel.selectedItems.contains(where: \.isImage)) {
                if let destination = FolderPicker.chooseFolder(title: "Choose PDF Destination") {
                    viewModel.previewCreatePDF(destination: destination, baseName: pdfBaseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Combined Images" : pdfBaseName)
                }
            }
        }
    }

    private func inspectorLabeledRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        LabeledContent {
            content()
        } label: {
            Text(title)
                .foregroundStyle(.secondary)
        }
    }

    private var issuesContent: some View {
        Group {
            if viewModel.review.duplicateGroups.isEmpty && viewModel.review.issues.isEmpty {
                Text("No issues detected.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.review.duplicateGroups) { group in
                    Text("Exact duplicate group: \(group.itemIDs.count) files, \(ByteCountFormatter.string(fromByteCount: group.byteSize, countStyle: .file)) each")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(viewModel.review.issues) { issue in
                    Label(issue.message, systemImage: issue.severity == .error ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(issue.severity == .error ? Color.red : Color.orange)
                }
            }
        }
    }

    private func actionButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .disabled(!enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
