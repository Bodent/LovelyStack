import AppKit
import ShelfDropCore
import SwiftUI

struct ShelfRootView: View {
    @ObservedObject private var viewModel: ShelfViewModel
    @StateObject private var sceneState: ShelfSceneState
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @SceneStorage("inspector.isPresented") private var isInspectorPresented = true
    @State private var renameShelfTitle = ""
    @State private var zipBaseName = "Shelf Bundle"
    @State private var pdfBaseName = "Combined Images"
    @State private var isDropTargeted = false
    @State private var pendingShelfDeletion: PendingShelfDeletion?

    init(viewModel: ShelfViewModel) {
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self._sceneState = StateObject(wrappedValue: ShelfSceneState(viewModel: viewModel))
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SessionsSidebar(
                sceneState: sceneState,
                renameShelfTitle: $renameShelfTitle,
                pendingShelfDeletion: $pendingShelfDeletion
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 300)
        } detail: {
            VStack(spacing: 0) {
                CenterHeaderBar(
                    sceneState: sceneState,
                    leadingTitleInset: isSidebarCollapsed ? 138 : 0
                )
                FileReviewBanner(sceneState: sceneState)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                Divider()

                DropShelfView(sceneState: sceneState, isDropTargeted: $isDropTargeted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(CenterPaneBackground())
            .ignoresSafeArea(.container, edges: .top)
            .navigationSplitViewColumnWidth(min: 400, ideal: 600)
            .inspector(isPresented: $isInspectorPresented) {
                VStack(spacing: 0) {
                    InspectorHeaderBar(searchText: $sceneState.searchText)
                    Divider()

                    InspectorPanel(
                        sceneState: sceneState,
                        zipBaseName: $zipBaseName,
                        pdfBaseName: $pdfBaseName
                    )
                }
                .ignoresSafeArea(.container, edges: .top)
                .inspectorColumnWidth(min: 300, ideal: 360, max: 450)
                .interactiveDismissDisabled()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .background(WindowSurfaceBackground())
        .sheet(item: $sceneState.pendingPreview) { pending in
            ActionPreviewSheet(
                pending: pending,
                onCancel: sceneState.dismissPreview,
                onConfirm: sceneState.confirmPendingPreview
            )
        }
        .alert("Action Error", isPresented: Binding(get: {
            sceneState.errorMessage != nil
        }, set: { shouldShow in
            if !shouldShow {
                sceneState.clearError()
            }
        })) {
            Button("OK", role: .cancel) {
                sceneState.clearError()
            }
        } message: {
            Text(sceneState.errorMessage ?? "Unknown error")
        }
        .confirmationDialog(
            "Delete Shelf?",
            isPresented: Binding(
                get: { pendingShelfDeletion != nil },
                set: { shouldShow in
                    if !shouldShow {
                        pendingShelfDeletion = nil
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: pendingShelfDeletion
        ) { pending in
            Button("Delete Shelf", role: .destructive) {
                sceneState.deleteShelf(sessionID: pending.sessionID)
                renameShelfTitle = sceneState.selectedSession.title
                pendingShelfDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingShelfDeletion = nil
            }
        } message: { pending in
            Text(pending.message)
        }
        .overlay(alignment: .topTrailing) {
            if sceneState.isBusy {
                ProgressView("Working…")
                    .padding(12)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding()
            }
        }
    }

    private var isSidebarCollapsed: Bool {
        columnVisibility == .detailOnly
    }
}

private struct CenterHeaderBar: View {
    @ObservedObject var sceneState: ShelfSceneState
    let leadingTitleInset: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Text("ShelfDrop")
                .font(.system(size: 18, weight: .semibold))
                .padding(.leading, leadingTitleInset)

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                HeaderActionButton(
                    title: "Add Files",
                    systemImage: "doc.badge.plus"
                ) {
                    sceneState.addFiles(urls: FolderPicker.chooseFiles())
                }

                HeaderActionButton(
                    title: sceneState.selectedSession.isPinned ? "Unpin Shelf" : "Pin Shelf",
                    systemImage: sceneState.selectedSession.isPinned ? "pin.slash" : "pin"
                ) {
                    sceneState.togglePinSelectedShelf()
                }

                HeaderActionButton(
                    title: "Undo",
                    systemImage: "arrow.uturn.backward"
                ) {
                    sceneState.performUndo()
                }
                .disabled(!sceneState.canUndo)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .animation(.smooth(duration: 0.22), value: leadingTitleInset)
    }
}

private struct InspectorHeaderBar: View {
    @Binding var searchText: String

    var body: some View {
        HStack {
            SearchField(text: $searchText)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 14)
    }
}

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search files, tags, or type", text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

private struct HeaderActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 30, height: 28)
        }
        .buttonStyle(.borderless)
        .help(title)
        .opacity(isEnabled ? 1 : 0.42)
    }
}

private struct CenterPaneBackground: View {
    var body: some View {
        Color(nsColor: .controlBackgroundColor)
    }
}

private struct WindowSurfaceBackground: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .ignoresSafeArea()
    }
}

private struct SessionsSidebar: View {
    @ObservedObject var sceneState: ShelfSceneState
    @Binding var renameShelfTitle: String
    @Binding var pendingShelfDeletion: PendingShelfDeletion?
    @FocusState private var isEditingShelfTitle: Bool

    var body: some View {
        List(selection: Binding(
            get: { sceneState.selectedSessionID },
            set: { newID in if let id = newID { sceneState.select(sessionID: id) } }
        )) {
            if !sceneState.pinnedSessions.isEmpty {
                Section("Pinned") {
                    ForEach(sceneState.pinnedSessions) { session in
                        SidebarRow(session: session)
                            .tag(session.id)
                            .contextMenu {
                                Button("Delete Shelf", role: .destructive) {
                                    requestDelete(session)
                                }
                            }
                    }
                }
            }

            Section("Recent") {
                ForEach(sceneState.recentSessions) { session in
                    SidebarRow(session: session)
                        .tag(session.id)
                        .contextMenu {
                            Button("Delete Shelf", role: .destructive) {
                                requestDelete(session)
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                TextField("Shelf title", text: Binding(
                    get: { renameShelfTitle },
                    set: { renameShelfTitle = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .focused($isEditingShelfTitle)
                .onSubmit {
                    renameShelfTitle = sceneState.renameSelectedShelfTitle(renameShelfTitle)
                }

                Button {
                    sceneState.createShelf()
                    renameShelfTitle = sceneState.selectedSession.title
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
            renameShelfTitle = sceneState.selectedSession.title
        }
        .onChange(of: sceneState.selectedSessionID) {
            renameShelfTitle = sceneState.selectedSession.title
        }
        .onChange(of: isEditingShelfTitle) {
            if !isEditingShelfTitle {
                renameShelfTitle = sceneState.renameSelectedShelfTitle(renameShelfTitle)
            }
        }
    }

    private func requestDelete(_ session: ShelfSession) {
        guard !session.items.isEmpty else {
            sceneState.deleteShelf(sessionID: session.id)
            renameShelfTitle = sceneState.selectedSession.title
            return
        }

        pendingShelfDeletion = PendingShelfDeletion(session: session)
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

private struct PendingShelfDeletion: Identifiable {
    let sessionID: UUID
    let title: String
    let itemCount: Int

    init(session: ShelfSession) {
        self.sessionID = session.id
        self.title = session.title
        self.itemCount = session.items.count
    }

    var id: UUID { sessionID }

    var message: String {
        let itemLabel = itemCount == 1 ? "item" : "items"
        return "Delete \"\(title)\"? Its \(itemCount) staged \(itemLabel) will be removed from ShelfDrop. Files on disk will not be deleted."
    }
}

private struct FileReviewBanner: View {
    @ObservedObject var sceneState: ShelfSceneState

    var body: some View {
        HStack(spacing: 16) {
            ReviewBadge(
                title: "Duplicates",
                value: "\(sceneState.review.duplicateGroups.count)",
                color: .orange
            )
            ReviewBadge(
                title: "Warnings",
                value: "\(sceneState.review.issues.filter { $0.severity == .warning }.count)",
                color: .yellow
            )
            ReviewBadge(
                title: "Blocking",
                value: "\(sceneState.review.issues.filter { $0.severity == .error }.count)",
                color: .red
            )
            Spacer()
            if !sceneState.selectedItemIDs.isEmpty {
                Text("\(sceneState.selectedItemIDs.count) selected")
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
    @ObservedObject var sceneState: ShelfSceneState
    @Binding var isDropTargeted: Bool

    var body: some View {
        ZStack {
            if sceneState.visibleItems.isEmpty {
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
                List(selection: $sceneState.selectedItemIDs) {
                    ForEach(sceneState.visibleItems) { item in
                        ShelfItemRow(
                            item: item,
                            duplicateGroup: sceneState.review.duplicateGroups.first(where: { $0.itemIDs.contains(item.id) }),
                            issues: sceneState.review.issues.filter { $0.itemID == item.id }
                        )
                        .tag(item.id)
                        .contextMenu {
                            Button("Quick Look") {
                                sceneState.openQuickLook()
                            }
                            Button("Reveal in Finder") {
                                sceneState.revealSelectedInFinder()
                            }
                            Button("Copy Paths") {
                                sceneState.copySelectedPaths()
                            }
                            Divider()
                            Button("Remove from Shelf", role: .destructive) {
                                sceneState.removeSelectedFromShelf()
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            let acceptedURLs = urls.filter(\.isFileURL)
            guard !acceptedURLs.isEmpty else { return false }
            sceneState.addFiles(urls: acceptedURLs)
            return true
        } isTargeted: { targeted in
            withAnimation(.easeInOut(duration: 0.2)) {
                isDropTargeted = targeted
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !sceneState.visibleItems.isEmpty {
                HStack {
                    Button("Quick Look") { sceneState.openQuickLook() }
                        .disabled(sceneState.selectedItemIDs.isEmpty)
                    SharingButton(urls: sceneState.selectedItems.map(\.url))
                        .frame(width: 60)
                    Spacer()
                    Button("Clear Shelf", role: .destructive) {
                        sceneState.clearShelf()
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
            ThumbnailView(url: item.url, size: CGSize(width: 48, height: 48))
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
    @ObservedObject var sceneState: ShelfSceneState
    @Binding var zipBaseName: String
    @Binding var pdfBaseName: String

    @SceneStorage("inspector.expanded.preview") private var isPreviewExpanded = true
    @SceneStorage("inspector.expanded.filing") private var isFilingExpanded = true
    @SceneStorage("inspector.expanded.rename") private var isRenameExpanded = false
    @SceneStorage("inspector.expanded.metadata") private var isMetadataExpanded = false
    @SceneStorage("inspector.expanded.transforms") private var isTransformsExpanded = false
    @SceneStorage("inspector.expanded.issues") private var isIssuesExpanded = true

    var body: some View {
        List {
            inspectorSection("Preview", isExpanded: $isPreviewExpanded) {
                previewContent
            }

            inspectorSection("File & Archive", isExpanded: $isFilingExpanded) {
                filingContent
            }

            inspectorSection("Rename Cleanup", isExpanded: $isRenameExpanded) {
                renameContent
            }

            inspectorSection("Finder Metadata", isExpanded: $isMetadataExpanded) {
                metadataContent
            }

            inspectorSection("Batch Transforms", isExpanded: $isTransformsExpanded) {
                transformsContent
            }

            inspectorSection("Trust Checks", isExpanded: $isIssuesExpanded) {
                issuesContent
            }
        }
        .listStyle(.sidebar)
        .controlSize(.small)
    }

    private var previewContent: some View {
        Group {
            if let item = sceneState.selectedItems.first {
                VStack(alignment: .center, spacing: 12) {
                    ThumbnailView(url: item.url, size: CGSize(width: 360, height: 240))
                        .frame(height: 160)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.displayName)
                            .font(.system(size: 12, weight: .medium))
                        Text(item.url.path)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(3)

                        if !item.tags.isEmpty {
                            Text(item.tags.joined(separator: ", "))
                                .font(.system(size: 11))
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
        inspectorGrid {
            actionButton("Move to Folder…", enabled: !sceneState.selectedItemIDs.isEmpty) {
                if let destination = FolderPicker.chooseFolder(title: "Move Selected Files") {
                    sceneState.previewMove(destination: destination, mode: .move)
                }
            }
            actionButton("Copy to Folder…", enabled: !sceneState.selectedItemIDs.isEmpty) {
                if let destination = FolderPicker.chooseFolder(title: "Copy Selected Files") {
                    sceneState.previewMove(destination: destination, mode: .copy)
                }
            }

            inspectorMenuPicker(
                "Archive Strategy",
                selection: $sceneState.archiveStrategy,
                options: Array(ArchiveStrategy.allCases)
            ) { strategy in
                strategy.displayName
            }

            actionButton("Archive to Root…", enabled: !sceneState.selectedItemIDs.isEmpty) {
                if let destination = FolderPicker.chooseFolder(title: "Choose Archive Root") {
                    sceneState.previewArchive(root: destination)
                }
            }

            actionButton("Safe Delete", enabled: !sceneState.selectedItemIDs.isEmpty) {
                sceneState.previewSafeDelete()
            }

            if !sceneState.recentDestinations.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent Destinations")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(sceneState.recentDestinations, id: \.self) { url in
                        Button(url.lastPathComponent) {
                            sceneState.previewMove(destination: url, mode: .move)
                        }
                        .disabled(sceneState.selectedItemIDs.isEmpty)
                        .buttonStyle(.link)
                    }
                }
            }
        }
    }

    private func inspectorSection<Content: View>(
        _ title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        DisclosureGroup(isExpanded: isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(.top, 10)
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var renameContent: some View {
        inspectorGrid {
            inspectorLabeledRow("Strip prefixes\n(comma sep.)") {
                TextField("", text: Binding(
                    get: { sceneState.renamePattern.prefixesToRemove.joined(separator: ", ") },
                    set: { newValue in
                        sceneState.renamePattern.prefixesToRemove = newValue
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                    }
                ), prompt: Text("IMG_, DSC_, Screenshot"))
            }

            inspectorLabeledRow("Remove text") {
                TextField("", text: Binding(
                    get: { sceneState.renamePattern.textToRemove.joined(separator: ", ") },
                    set: { newValue in
                        sceneState.renamePattern.textToRemove = newValue
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                    }
                ))
            }

            inspectorMenuPicker(
                "Separator",
                selection: $sceneState.renamePattern.separator,
                options: Array(RenameSeparator.allCases)
            ) { separator in
                separator.displayName
            }

            inspectorMenuPicker(
                "Case Style",
                selection: $sceneState.renamePattern.caseStyle,
                options: Array(RenameCaseStyle.allCases)
            ) { style in
                style.rawValue.capitalized
            }

            inspectorMenuPicker(
                "Append Date",
                selection: $sceneState.renamePattern.dateSource,
                options: Array(RenameDateSource.allCases)
            ) { source in
                source.rawValue.capitalized
            }

            inspectorLabeledRow("Include Counter") {
                Toggle("Include Counter", isOn: $sceneState.renamePattern.includeCounter)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            inspectorLabeledRow("Custom Prefix") {
                TextField("", text: $sceneState.renamePattern.customPrefix)
            }
            inspectorLabeledRow("Custom Suffix") {
                TextField("", text: $sceneState.renamePattern.customSuffix)
            }

            actionButton("Preview Rename", enabled: !sceneState.selectedItemIDs.isEmpty) {
                sceneState.previewRename()
            }
        }
    }

    private var metadataContent: some View {
        inspectorGrid {
            inspectorLabeledRow("Tags (comma sep.)") {
                TextField("", text: Binding(
                    get: { sceneState.metadataRequest.tags.joined(separator: ", ") },
                    set: { value in
                        sceneState.metadataRequest.tags = value
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                    }
                ))
            }

            inspectorMenuPicker(
                "Finder Label",
                selection: $sceneState.metadataRequest.label,
                options: Array(FinderLabelColor.allCases)
            ) { label in
                label.displayName
            }

            inspectorLabeledRow("Finder Comment") {
                TextField("", text: Binding(
                    get: { sceneState.metadataRequest.comment ?? "" },
                    set: { sceneState.metadataRequest.comment = $0 }
                ), axis: .vertical)
                .lineLimit(3...5)
            }

            actionButton("Preview Metadata", enabled: !sceneState.selectedItemIDs.isEmpty) {
                sceneState.previewMetadata()
            }
        }
    }

    private var transformsContent: some View {
        inspectorGrid {
            inspectorLabeledRow("ZIP Name") {
                TextField("", text: $zipBaseName)
            }
            actionButton("Create ZIP…", enabled: !sceneState.selectedItemIDs.isEmpty) {
                if let destination = FolderPicker.chooseFolder(title: "Choose ZIP Destination") {
                    sceneState.previewZip(destination: destination, baseName: zipBaseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Shelf Bundle" : zipBaseName)
                }
            }

            Divider()

            inspectorMenuPicker(
                "Image Output",
                selection: $sceneState.imageTransformPlan.outputFormat,
                options: Array(ImageOutputFormat.allCases)
            ) { format in
                format.rawValue.uppercased()
            }

            inspectorLabeledRow("Strip Metadata") {
                Toggle("Strip Metadata", isOn: $sceneState.imageTransformPlan.stripMetadata)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            inspectorLabeledRow("Max Size (px)") {
                TextField("", text: maxPixelSizeTextBinding, prompt: Text("Original size"))
            }

            actionButton("Convert Images…", enabled: sceneState.selectedItems.contains(where: \.isImage)) {
                if let destination = FolderPicker.chooseFolder(title: "Choose Image Output Folder") {
                    sceneState.previewImageTransform(destination: destination)
                }
            }

            Divider()

            inspectorLabeledRow("PDF Name") {
                TextField("", text: $pdfBaseName)
            }
            actionButton("Create PDF from Images…", enabled: sceneState.selectedItems.contains(where: \.isImage)) {
                if let destination = FolderPicker.chooseFolder(title: "Choose PDF Destination") {
                    sceneState.previewCreatePDF(destination: destination, baseName: pdfBaseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Combined Images" : pdfBaseName)
                }
            }
        }
    }

    private func inspectorGrid<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inspectorMenuPicker<Value: Hashable>(
        _ title: String,
        selection: Binding<Value>,
        options: [Value],
        optionTitle: @escaping (Value) -> String
    ) -> some View {
        inspectorLabeledRow(title) {
            if #available(macOS 26.0, *) {
                inspectorPickerControl(
                    selection: selection,
                    options: options,
                    optionTitle: optionTitle
                )
                .buttonSizing(.flexible)
            } else {
                inspectorPickerControl(
                    selection: selection,
                    options: options,
                    optionTitle: optionTitle
                )
            }
        }
    }

    private func inspectorPickerControl<Value: Hashable>(
        selection: Binding<Value>,
        options: [Value],
        optionTitle: @escaping (Value) -> String
    ) -> some View {
        Picker("", selection: selection) {
            ForEach(options, id: \.self) { option in
                Text(optionTitle(option)).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .multilineTextAlignment(.trailing)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inspectorLabeledRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 112, alignment: .leading)

            content()
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var issuesContent: some View {
        Group {
            if sceneState.review.duplicateGroups.isEmpty && sceneState.review.issues.isEmpty {
                Text("No issues detected.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sceneState.review.duplicateGroups) { group in
                    Text("Exact duplicate group: \(group.itemIDs.count) files, \(ByteCountFormatter.string(fromByteCount: group.byteSize, countStyle: .file)) each")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(sceneState.review.issues) { issue in
                    Label(issue.message, systemImage: issue.severity == .error ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(issue.severity == .error ? Color.red : Color.orange)
                }
            }
        }
    }

    private func actionButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 12))
            .disabled(!enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var maxPixelSizeTextBinding: Binding<String> {
        Binding(
            get: {
                sceneState.imageTransformPlan.maxPixelSize.map(String.init) ?? ""
            },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                sceneState.imageTransformPlan.maxPixelSize = Int(trimmed)
            }
        )
    }
}
