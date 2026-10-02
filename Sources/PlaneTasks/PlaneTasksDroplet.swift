import AppKit
import Combine
import DroppyKit
import Foundation
import Security
import SwiftUI
import WebKit

@objc(PlaneTasksPrincipal)
public final class PlaneTasksPrincipal: NSObject, DropletPrincipal {
    public override init() { super.init() }
    @MainActor public func makeDroplet() -> AnyObject { PlaneTasksDroplet() }
}

@MainActor
public final class PlaneTasksDroplet: NSObject, ObservableObject, Droplet {
    public nonisolated static let id: DropletID = "plane-tasks"
    @Published fileprivate var tasks: [PlaneTask] = []
    @Published fileprivate var state: LoadState = .needsSetup
    @Published fileprivate var settingsRevision = 0
    @Published fileprivate var selectedProject = "All"
    @Published fileprivate var selectedStatuses: Set<String> = []
    @Published fileprivate var searchText = ""
    @Published fileprivate var selectedTaskID: String?
    @Published fileprivate var isRefreshing = false
    @Published fileprivate var refreshRevision = 0
    @Published fileprivate var refreshError: String?
    @Published fileprivate var listTab: ListTab = .all
    @Published fileprivate var pinnedIDs: Set<String> = []
    @Published fileprivate var newIDs: Set<String> = []
    private var seenIDs: Set<String> = []
    private var hasBaseline = false
    private var pollTask: Task<Void, Never>?
    private var clearActivityTask: Task<Void, Never>?
    private let activitySubject = CurrentValueSubject<LiveActivityState?, Never>(nil)
    private var host: DropletHost?
    fileprivate var layoutIsCompact = false
    private var reloadTask: Task<Void, Never>?
    private let tokenStore = TokenStore(service: "app.getdroppy.plane-tasks")
    
    public func activate(host: DropletHost) throws { self.host = host; host.log.info("Plane Tasks activated"); loadPins(); loadSeen(); refresh(); startPolling() }
    public func deactivate() {
        pollTask?.cancel(); pollTask = nil
        clearActivityTask?.cancel(); clearActivityTask = nil
        activitySubject.send(nil)
        reloadTask?.cancel(); reloadTask = nil
        host = nil
    }
    public func refresh() {
        reloadTask?.cancel()
        refreshRevision += 1
        // Show the skeleton on the very first frame instead of waiting for the
        // task below to get its first turn on the main actor.
        if tasks.isEmpty && isConfigured { state = .loading }
        reloadTask = Task { [weak self] in await self?.loadTasks() }
    }

    private var workspace: String { host?.preferences.value(forKey: "workspace", default: "").trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    private var baseURL: String { (host?.preferences.value(forKey: "baseURL", default: "https://api.plane.so") ?? "https://api.plane.so").trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) }

    /// When "All projects" is selected, these are the standard Plane status
    /// groups (Backlog, Todo, In Progress, Done, Cancelled) merged across
    /// every project, even if each project names its states differently.
    /// With one project selected, these are that project's own status names.
    fileprivate var statusFilterOptions: [StatusFilterOption] {
        if selectedProject == "All" {
            let order = ["backlog", "unstarted", "started", "completed", "cancelled"]
            let present = Set(tasks.map(\.stateGroup).filter { !$0.isEmpty })
            let ordered = order.filter { present.contains($0) } + present.subtracting(order).sorted()
            return ordered.map { StatusFilterOption(id: $0, label: Self.groupDisplayName($0), group: $0) }
        } else {
            var groupByStatus: [String: String] = [:]
            for task in tasks where task.project == selectedProject && !task.status.isEmpty && task.status != "Unknown" {
                if groupByStatus[task.status] == nil { groupByStatus[task.status] = task.stateGroup }
            }
            return groupByStatus.keys.sorted().map { StatusFilterOption(id: $0, label: $0, group: groupByStatus[$0] ?? "") }
        }
    }

    fileprivate static func groupDisplayName(_ group: String) -> String {
        switch group.lowercased() {
        case "backlog": return "Backlog"
        case "unstarted": return "Todo"
        case "started": return "In Progress"
        case "completed": return "Done"
        case "cancelled": return "Cancelled"
        default: return group.isEmpty ? "Unknown" : group.capitalized
        }
    }
    fileprivate var projects: [String] { ["All"] + Array(Set(tasks.map(\.project).filter { !$0.isEmpty })).sorted() }
    /// `tasks` is sorted (newest first) once when it loads, so this only
    /// filters. It runs several times per render, so it must stay cheap.
    fileprivate var visibleTasks: [PlaneTask] { filteredTasks(for: listTab) }
    fileprivate func filteredTasks(for tab: ListTab) -> [PlaneTask] {
        tasks.filter { task in
            let matchesSearch = searchText.isEmpty
                || task.name.localizedCaseInsensitiveContains(searchText)
                || task.reference.localizedCaseInsensitiveContains(searchText)
                || task.project.localizedCaseInsensitiveContains(searchText)
            // The Pinned tab ignores project and status on purpose.
            if tab == .pinned { return pinnedIDs.contains(task.id) && matchesSearch }
            let statusMatches = selectedStatuses.isEmpty
                || (selectedProject == "All" ? selectedStatuses.contains(task.stateGroup) : selectedStatuses.contains(task.status))
            return statusMatches && (selectedProject == "All" || task.project == selectedProject) && matchesSearch
        }
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoPlain = ISO8601DateFormatter()

    /// Parses a Plane API timestamp for sorting. Tasks with no parseable
    /// date sort to the very end rather than the very front.
    private static func parseDate(_ raw: String?) -> Date {
        guard let raw, !raw.isEmpty else { return .distantPast }
        return isoWithFraction.date(from: raw) ?? isoPlain.date(from: raw) ?? .distantPast
    }

    /// Number of tasks per status chip (nil = the "All" chip), respecting the
    /// selected project and the search text so the numbers match the list.
    fileprivate func taskCount(status id: String?) -> Int {
        tasks.reduce(0) { total, task in
            let matchesSearch = searchText.isEmpty
                || task.name.localizedCaseInsensitiveContains(searchText)
                || task.reference.localizedCaseInsensitiveContains(searchText)
                || task.project.localizedCaseInsensitiveContains(searchText)
            guard matchesSearch, selectedProject == "All" || task.project == selectedProject else { return total }
            if let id {
                let key = selectedProject == "All" ? task.stateGroup : task.status
                guard key == id else { return total }
            }
            return total + 1
        }
    }

    // MARK: Pins

    private func loadPins() {
        let raw = host?.preferences.value(forKey: "pinnedTaskIDs", default: "") ?? ""
        if let data = raw.data(using: .utf8), let ids = try? JSONDecoder().decode([String].self, from: data) {
            pinnedIDs = Set(ids)
        }
    }

    fileprivate func togglePin(_ task: PlaneTask) {
        if pinnedIDs.contains(task.id) { pinnedIDs.remove(task.id) } else { pinnedIDs.insert(task.id) }
        if let data = try? JSONEncoder().encode(pinnedIDs.sorted()), let json = String(data: data, encoding: .utf8) {
            host?.preferences.setValue(json, forKey: "pinnedTaskIDs")
        }
    }

    // MARK: New-task alerts

    private var notifiesNewTasks: Bool { host?.preferences.value(forKey: "notifyNewTasks", default: true) ?? true }
    private var pollMinutes: Int { host?.preferences.value(forKey: "pollMinutes", default: 5) ?? 5 }

    var notifyBinding: Binding<Bool> {
        Binding(
            get: { self.notifiesNewTasks },
            set: {
                self.host?.preferences.setValue($0, forKey: "notifyNewTasks")
                if !$0 { self.markNewSeen() }
                self.startPolling()
                self.settingsRevision += 1
            }
        )
    }

    private var alertSeconds: Int { host?.preferences.value(forKey: "alertSeconds", default: 5) ?? 5 }

    var alertSecondsBinding: Binding<Int> {
        Binding(
            get: { self.alertSeconds },
            set: { self.host?.preferences.setValue($0, forKey: "alertSeconds"); self.settingsRevision += 1 }
        )
    }

    var pollMinutesBinding: Binding<Int> {
        Binding(
            get: { self.pollMinutes },
            set: {
                self.host?.preferences.setValue($0, forKey: "pollMinutes")
                self.startPolling()
                self.settingsRevision += 1
            }
        )
    }

    /// Started in `activate`, cancelled in `deactivate` and on every settings change.
    private func startPolling() {
        pollTask?.cancel(); pollTask = nil
        guard notifiesNewTasks else { return }
        let seconds = max(1, pollMinutes) * 60
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, let self else { return }
                if self.isConfigured && !self.isRefreshing { self.refresh() }
            }
        }
    }

    private func loadSeen() {
        let raw = host?.preferences.value(forKey: "seenTaskIDs", default: "") ?? ""
        if let data = raw.data(using: .utf8), let ids = try? JSONDecoder().decode([String].self, from: data) {
            seenIDs = Set(ids); hasBaseline = true
        }
    }

    private func saveSeen() {
        if let data = try? JSONEncoder().encode(seenIDs.sorted()), let json = String(data: data, encoding: .utf8) {
            host?.preferences.setValue(json, forKey: "seenTaskIDs")
        }
    }

    /// The first successful load is only the baseline; later loads compare against it.
    private func detectNewTasks() {
        let current = Set(tasks.map(\.id))
        guard hasBaseline else { seenIDs = current; hasBaseline = true; saveSeen(); return }
        let fresh = current.subtracting(seenIDs)
        guard !fresh.isEmpty else { return }
        seenIDs.formUnion(fresh); saveSeen()
        guard notifiesNewTasks else { return }
        newIDs.formUnion(fresh)
        announce()
    }

    /// Fixed priority and isInteractive; only the title changes. `nil` when the alert ends.
    private func announce() {
        let count = newIDs.count
        activitySubject.send(LiveActivityState(
            priority: 150,
            accessibilityTitle: count == 1 ? "1 new Plane task" : "\(count) new Plane tasks",
            isInteractive: false
        ))
        clearActivityTask?.cancel()
        clearActivityTask = Task { [weak self] in
            let seconds = self?.alertSeconds ?? 5
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.activitySubject.send(nil)
        }
    }

    /// Clears the tab badge and stands the live activity down.
    fileprivate func markNewSeen() {
        newIDs = []
        clearActivityTask?.cancel(); clearActivityTask = nil
        activitySubject.send(nil)
    }

    /// What the settings status chip shows. It reflects the last real request,
    /// not just "both fields are filled in".
    fileprivate var connectionStatus: ConnectionStatus {
        guard isConfigured else { return .needsSetup }
        if isRefreshing || state == .loading || state == .needsSetup { return .checking }
        if let refreshError { return .failed(refreshError) }
        if case .failed(let message) = state { return .failed(message) }
        return .connected
    }

    /// Called whenever workspace, URL or token changes: drop stale data and
    /// re-check, so the status chip never keeps saying "Ready" for old credentials.
    fileprivate func credentialsChanged() {
        settingsRevision += 1
        seenIDs = []; hasBaseline = false
        host?.preferences.setValue("", forKey: "seenTaskIDs")
        markNewSeen()
        tasks = []
        selectedTaskID = nil
        refreshError = nil
        refresh()
    }
    fileprivate var selectedTask: PlaneTask? { tasks.first { $0.id == selectedTaskID } }

    private func loadTasks() async {
        guard !workspace.isEmpty, let token = tokenStore.read(), !token.isEmpty else { state = .needsSetup; tasks = []; return }
        guard let base = URL(string: baseURL) else { state = .failed("The Plane URL is invalid."); return }
        let keepsCurrentTasks = !tasks.isEmpty
        isRefreshing = keepsCurrentTasks
        refreshError = nil
        if !keepsCurrentTasks { state = .loading }
        defer { isRefreshing = false }
        do {
            let webBaseURL = base.host == "api.plane.so" ? URL(string: "https://app.plane.so")! : base
            let client = PlaneClient(baseURL: base, webBaseURL: webBaseURL, workspace: workspace, token: token)
            let currentUser = try await client.currentUser()
            let projects = try await client.projects()
            let lists = try await withThrowingTaskGroup(of: [PlaneTask].self) { group in
                for project in projects { group.addTask { try await client.tasks(in: project, assignedTo: currentUser.id) } }
                var all: [PlaneTask] = []; for try await list in group { all += list }; return all
            }
            // Sort once here (newest first) instead of on every render.
            tasks = lists
                .map { ($0, Self.parseDate($0.createdAt)) }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
            state = .loaded
            detectNewTasks()
            host?.log.info("Plane Tasks loaded \(tasks.count) assigned tasks")
        } catch is CancellationError { return
        } catch let error as URLError where error.code == .cancelled { return
        } catch {
            if keepsCurrentTasks {
                refreshError = error.localizedDescription
                state = .loaded
            } else {
                tasks = []
                state = .failed(error.localizedDescription)
            }
            host?.log.error("Plane Tasks request failed: \(error.localizedDescription)")
        }
    }

    var workspaceBinding: Binding<String> {
        Binding(
            get: { self.workspace },
            set: {
                self.host?.preferences.setValue($0, forKey: "workspace")
                self.credentialsChanged()
            }
        )
    }

    var baseURLBinding: Binding<String> {
        Binding(
            get: { self.baseURL },
            set: {
                self.host?.preferences.setValue($0, forKey: "baseURL")
                self.credentialsChanged()
            }
        )
    }

    var tokenBinding: Binding<String> {
        Binding(
            get: { self.tokenStore.read() ?? "" },
            set: {
                self.tokenStore.write($0)
                self.credentialsChanged()
            }
        )
    }
    var isConfigured: Bool { !workspace.isEmpty && !(tokenStore.read() ?? "").isEmpty }
    func openSettings() { _ = host?.workspace.openSettings() }
}

extension PlaneTasksDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [ShelfWidgetDescriptor(id: "plane-tasks", title: "Plane Tasks", systemImage: "checklist", layoutTraits: ShelfWidgetLayoutTraits(preferredSoloWidth: 520, preferredPairedWidth: 260, contentHeight: .fixed(widgetContentHeight)), searchKeywords: ["plane", "tasks", "assigned", "work items"])]
    }

    /// The shelf takes one height per widget, and `widgetDescriptors` is the only
    /// place to declare it. The solo widget keeps its 340; the paired (compact)
    /// widget stays at a short fixed height and scrolls its content.
    fileprivate var widgetContentHeight: CGFloat { layoutIsCompact ? 180 : 340 }

    /// Called by the widget view when it learns whether it is paired.
    fileprivate func reportLayout(isCompact: Bool) {
        guard layoutIsCompact != isCompact else { return }
        layoutIsCompact = isCompact
        host?.shelf.invalidateLayout(for: "plane-tasks")
    }
    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView { AnyView(PlaneTasksWidget(droplet: self, context: context)) }
    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? { nil }
}

extension PlaneTasksDroplet: LiveActivityProviding {
    public var liveActivityState: AnyPublisher<LiveActivityState?, Never> { activitySubject.eraseToAnyPublisher() }

    public func makeCompactLeading() -> AnyView {
        AnyView(
            Image(systemName: "checklist")
                .font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .medium))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .padding(.trailing, DroppySpacing.sm)
        )
    }

    public func makeCompactTrailing() -> AnyView { AnyView(NewTasksCountLabel(droplet: self)) }

    /// Droppy does not mount this; controls live in the shelf widget.
    public func makeExpanded(context: LiveActivityContext) -> AnyView { AnyView(EmptyView()) }
}

private struct NewTasksCountLabel: View {
    @ObservedObject var droplet: PlaneTasksDroplet
    var body: some View {
        Text("+\(droplet.newIDs.count)")
            .font(.system(size: DroppyLiveActivityMetrics.labelFontSize, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            .padding(.horizontal, DroppySpacing.sm)
            .padding(.vertical, DroppySpacing.xs)
            .background(Color.blue.opacity(0.35), in: Capsule(style: .continuous))
            .padding(.leading, DroppySpacing.sm)
    }
}

extension PlaneTasksDroplet: SettingsPaneProviding {
    public func makeSettingsPane(context: SettingsPaneContext) -> AnyView { AnyView(PlaneTasksSettings(droplet: self)) }
    public var settingsSearchEntries: [SettingsSearchEntry] { [SettingsSearchEntry(title: "Plane connection", keywords: ["plane", "token", "workspace", "API"]), SettingsSearchEntry(title: "New task alerts", keywords: ["notify", "notification", "polling", "interval"])] }
}

fileprivate struct StatusFilterOption: Identifiable {
    let id: String
    let label: String
    let group: String
}

private struct PlaneTasksWidget: View {
    @ObservedObject var droplet: PlaneTasksDroplet
    let context: ShelfWidgetContext
    @State private var isProjectPopoverPresented = false
    @State private var chipsOffsetX: CGFloat = 0
    @State private var chipsContentWidth: CGFloat = 0
    @State private var chipsViewportWidth: CGFloat = 0
    @State private var copiedFeedback: String? = nil
    @State private var detailTask: PlaneTask?
    @State private var isShowingDetail = false
    @State private var isInitialLoading = false
    @State private var listOffsetY: CGFloat = 0
    @State private var listContentHeight: CGFloat = 0
    @State private var listViewportHeight: CGFloat = 0
    @State private var detailOffsetY: CGFloat = 0
    @State private var detailContentHeight: CGFloat = 0
    @State private var detailViewportHeight: CGFloat = 0
    @State private var descriptionHeight: CGFloat = 0
    private let cardRadius: CGFloat = 20

    var body: some View {
        Group {
            Group {
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        taskListScreen
                            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                            .offset(x: isShowingDetail ? -proxy.size.width : 0)

                        if let detailTask {
                            detailScreen(detailTask)
                                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                                .offset(x: isShowingDetail ? 0 : proxy.size.width)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                    .clipped()
                    .mask(Rectangle())
                }
            }
        }
        // No bottom inset: the list and the detail page run to the bottom edge
        // and dissolve there with the edge fade.
        .padding(EdgeInsets(
            top: context.contentInsets.top,
            leading: context.contentInsets.leading,
            bottom: 0,
            trailing: context.contentInsets.trailing
        ))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { droplet.reportLayout(isCompact: context.isCompact) }
        .onChange(of: context.isCompact) { _, newValue in droplet.reportLayout(isCompact: newValue) }
    }

    /// Animating the state change makes the filters fade out and the list
    /// glide up, instead of the layout snapping.
    private func setTab(_ tab: ListTab) {
        guard droplet.listTab != tab else { return }
        withAnimation(.snappy(duration: 0.3)) { droplet.listTab = tab }
    }

    /// Compact widgets only ever show the pinned tab (and task details);
    /// the shared `listTab` is left alone so the full widget keeps its own tab.
    private var effectiveTab: ListTab { context.isCompact ? .pinned : droplet.listTab }

    private var taskListScreen: some View {
        VStack(alignment: .leading, spacing: 10) {
            listHeader
                .padding(.bottom, 4)
            switch droplet.state {
                case .needsSetup:
                    infoBox(
                        icon: "info.circle.fill",
                        tint: .blue,
                        title: "Connect your Plane workspace",
                        message: "Add your workspace slug and a personal access token in settings to see the tasks assigned to you.",
                        actionTitle: "Open settings",
                        action: { droplet.openSettings() }
                    )
                case .loading:
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(0..<4, id: \.self) { index in
                            taskSkeletonRow(index: index)
                        }
                    }
                    .shimmering()
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Loading tasks")
                case .loaded:
                    // The compact widget has no search field, so this block is empty there
                    // unless there is an error. An empty VStack would still add a 10pt gap
                    // above the list, so it is left out entirely instead.
                    if !context.isCompact || droplet.refreshError != nil {
                        VStack(alignment: .leading, spacing: 10) {
                            if let message = droplet.refreshError {
                                errorBox(message)
                            }
                            if !context.isCompact {
                                HStack(spacing: DroppySpacing.sm) {
                                    searchField
                                    // The Pinned tab ignores project and status, so the filters hide there.
                                    if effectiveTab == .all {
                                        projectFilter
                                    }
                                }
                            }
                            if effectiveTab == .all {
                                statusChips
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                        .onChange(of: droplet.searchText) { _, _ in
                            droplet.selectedTaskID = nil
                        }
                    }
                    taskList
                case .failed(let message):
                    errorBox(message)
            }
            Spacer(minLength: 0)
        }
    }

    private var listHeader: some View {
        HStack(spacing: DroppySpacing.xsm) {
            Image(systemName: "checklist")
                .font(.system(size: 11, weight: .medium))
            Text(context.isCompact ? "Pinned Tasks" : "Plane Tasks")
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
            HStack(spacing: DroppySpacing.sm) {
                if !context.isCompact {
                    headerButton(
                        symbol: "line.3.horizontal.decrease",
                        isActive: effectiveTab == .all,
                        help: "All tasks"
                    ) {
                        droplet.markNewSeen()
                        setTab(.all)
                    }
                    headerButton(
                        symbol: "pin.fill",
                        isActive: effectiveTab == .pinned,
                        activeTint: .blue,
                        help: "Pinned tasks"
                    ) {
                        setTab(.pinned)
                    }
                }
                Button { droplet.refresh() } label: {
                    Group {
                        if droplet.isRefreshing {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.10)))
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(droplet.isRefreshing)
                .help("Refresh")
                .accessibilityLabel("Refresh")
            }
        }
        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
    }

    private func headerButton(symbol: String, isActive: Bool, activeTint: Color = AdaptiveColors.notchSurfacePrimaryText, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isActive ? activeTint : AdaptiveColors.notchSurfaceSecondaryText)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(isActive ? 0.14 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.2), value: isActive)
        .help(help)
        .accessibilityLabel(help)
    }

    private var searchField: some View {
        HStack(spacing: DroppySpacing.xsm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            TextField("Search title, ID, project…", text: $droplet.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            if !droplet.searchText.isEmpty {
                Button {
                    droplet.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(AdaptiveColors.notchSurfaceCardFill, in: Capsule(style: .continuous))
    }

    /// Scrolling task list with the same edge fade as the status chips: the
    /// fade only shows on a side that still has content to reveal.
    private var canScrollListUp: Bool { listOffsetY > 1 }
    private var canScrollListDown: Bool { (listContentHeight - listViewportHeight - listOffsetY) > 1 }

    private var taskList: some View {
        GeometryReader { proxy in
            let visible = context.isCompact
                ? droplet.tasks.filter { droplet.pinnedIDs.contains($0.id) }
                : droplet.filteredTasks(for: effectiveTab)
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ScrollViewScrollerHider()
                        .frame(width: 0, height: 0)
                    ForEach(visible) { task in
                        if context.isCompact {
                            compactTaskRow(task)
                        } else {
                            taskRow(task)
                        }
                    }
                    if visible.isEmpty {
                        if effectiveTab == .pinned && (droplet.searchText.isEmpty || context.isCompact) {
                            emptyState(icon: "pin.slash", title: "No pinned tasks", message: "Use the pin button on a task to keep it here.")
                        } else if effectiveTab == .pinned {
                            emptyState(icon: "magnifyingglass", title: "No pinned tasks match", message: "Try a different search term.")
                        } else {
                            emptyState(icon: "tray", title: "No tasks match these filters", message: "Try a different status, project, or search term.")
                        }
                    }
                }
                .padding(.bottom, 8)
                .frame(width: proxy.size.width, alignment: .leading)
            }
            .scrollIndicators(.hidden, axes: .vertical)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { _, newValue in
                listOffsetY = newValue
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height
            } action: { _, newValue in
                listContentHeight = newValue
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.containerSize.height
            } action: { _, newValue in
                listViewportHeight = newValue
            }
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [.clear, .black],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: canScrollListUp ? 28 : 0)

                    Color.black

                    LinearGradient(
                        colors: [.black, .clear],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: canScrollListDown ? 28 : 0)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: canScrollListUp)
            .animation(.easeInOut(duration: 0.15), value: canScrollListDown)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var projectFilter: some View {
        Button {
            isProjectPopoverPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11, weight: .medium))
                Text(droplet.selectedProject == "All" ? "Select project" : droplet.selectedProject)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(width: 150)
            .background(AdaptiveColors.notchSurfaceCardFill, in: Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Filter by project")
        .popover(isPresented: $isProjectPopoverPresented, arrowEdge: .bottom) {
            projectMenu
                .presentationCompactAdaptation(.popover)
        }
    }

    /// Menu-style list: no header, checkmark column, accent highlight on hover.
    private var projectMenu: some View {
        let names = droplet.projects.filter { $0 != "All" }
        let rows = VStack(alignment: .leading, spacing: 1) {
            projectOption("All projects", value: "All")
            if !names.isEmpty {
                Divider()
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
            }
            ForEach(names, id: \.self) { project in
                projectOption(project, value: project)
            }
        }
        return Group {
            if names.count > 8 {
                ScrollView {
                    rows
                }
                .scrollIndicators(.hidden)
                .frame(height: 240)
            } else {
                rows
            }
        }
        .padding(6)
        .frame(minWidth: 200, maxWidth: 280)
    }

    private func projectOption(_ title: String, value: String) -> some View {
        ProjectMenuRow(title: title, isSelected: droplet.selectedProject == value) {
            droplet.selectedProject = value
            droplet.selectedStatuses.removeAll()
            droplet.selectedTaskID = nil
            isProjectPopoverPresented = false
        }
    }

    private var canScrollChipsLeft: Bool { chipsOffsetX > 1 }
    private var canScrollChipsRight: Bool { (chipsContentWidth - chipsViewportWidth - chipsOffsetX) > 1 }

    private var statusChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DroppySpacing.xsm) {
                chip(label: "All", isSelected: droplet.selectedStatuses.isEmpty, count: droplet.taskCount(status: nil)) {
                    withAnimation(.snappy(duration: 0.22)) {
                        droplet.selectedStatuses.removeAll()
                    }
                }
                ForEach(droplet.statusFilterOptions) { option in
                    let isOn = droplet.selectedStatuses.contains(option.id)
                    chip(label: option.label, isSelected: isOn, dotColor: groupColor(option.group), count: droplet.taskCount(status: option.id)) {
                        withAnimation(.snappy(duration: 0.22)) {
                            if isOn {
                                droplet.selectedStatuses.remove(option.id)
                            } else {
                                droplet.selectedStatuses.insert(option.id)
                            }
                        }
                    }
                }
            }
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.x
        } action: { _, newValue in
            chipsOffsetX = newValue
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentSize.width
        } action: { _, newValue in
            chipsContentWidth = newValue
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.containerSize.width
        } action: { _, newValue in
            chipsViewportWidth = newValue
        }
        // Fade the clipped end of the status row instead of ending abruptly
        // beside the project filter — but only on the side that actually
        // still has more chips to reveal, and it disappears once you've
        // scrolled all the way there.
        .mask {
            HStack(spacing: 0) {
                LinearGradient(
                    colors: [.clear, .black],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: canScrollChipsLeft ? 18 : 0)

                Color.black

                LinearGradient(
                    colors: [.black, .clear],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: canScrollChipsRight ? 18 : 0)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: canScrollChipsLeft)
        .animation(.easeInOut(duration: 0.15), value: canScrollChipsRight)
    }

    /// Standard Plane status-group colors: gray for backlog, blue for
    /// todo/unstarted, orange for in progress, green for done, red for
    /// cancelled. Anything else falls back to gray.
    private func groupColor(_ group: String) -> Color {
        switch group.lowercased() {
        case "backlog": return .gray
        case "unstarted": return .blue
        case "started": return .orange
        case "completed": return .green
        case "cancelled": return .red
        default: return .gray
        }
    }

    private func chip(label: String, isSelected: Bool, dotColor: Color? = nil, count: Int? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let dotColor {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 7, height: 7)
                }
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.12), in: Capsule(style: .continuous))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(isSelected ? AdaptiveColors.notchSurfacePrimaryText : AdaptiveColors.notchSurfaceSecondaryText)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(isSelected ? 0.12 : 0))
            }
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.22), value: isSelected)
        .help(isSelected ? "Selected" : "Filter by \(label)")
    }

    /// Centered empty state, like a native "content unavailable" view:
    /// hierarchical SF Symbol, short title, one line of guidance, on a flat
    /// raised tile (no outline, no gradient).
    private func emptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: DroppySpacing.xsm) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                .padding(.bottom, DroppySpacing.xs)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DroppySpacing.mdl)
        .padding(.horizontal, DroppySpacing.md)
        .background(AdaptiveColors.notchSurfaceCardFill, in: RoundedRectangle(cornerRadius: DroppyRadius.medium, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// A native-style callout: tinted symbol, title, explanation and an
    /// optional action, on a flat tinted fill (no outline).
    private func infoBox(icon: String, tint: Color, title: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: DroppySpacing.sm) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DroppySpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: DroppyRadius.medium, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    /// Collapses every newline / run of spaces so the description is a single
    /// line that truncates with an ellipsis instead of wrapping.
    private func singleLine(_ text: String) -> String {
        String(text.prefix(300))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Narrow card for compact widgets: reference + one-line title, then
    /// priority (icon only), state and date. Everything can shrink, so
    /// nothing is ever wider than the widget. Project and description are
    /// left to the detail page.
    private func compactTaskRow(_ task: PlaneTask) -> some View {
        let shape = RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
        return ZStack(alignment: .topTrailing) {
            Button {
                showDetails(for: task)
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.reference.uppercased())
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            .lineLimit(1)
                        Text(task.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.trailing, 52)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 6) {
                        priorityChip(task.priority, iconOnly: true)
                            .fixedSize()
                            .layoutPriority(2)
                        stateChip(task)
                        Spacer(minLength: 4)
                        if let date = formattedTargetDate(task.targetDate) {
                            Text(date)
                                .font(.system(size: 10, weight: .regular))
                                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                                .lineLimit(1)
                                .fixedSize()
                                .layoutPriority(1)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .help("Show task details")

            HStack(spacing: 6) {
                copyRowButton(task)
                pinRowButton(task)
            }
            .padding(.top, 10)
            .padding(.trailing, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AdaptiveColors.notchSurfaceCardFill, in: shape)
        .contentShape(shape)
    }

    private func taskRow(_ task: PlaneTask) -> some View {
        let shape = RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
        return ZStack(alignment: .topTrailing) {
            Button {
                showDetails(for: task)
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.reference.uppercased())
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            .lineLimit(1)

                        Text(task.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if !task.descriptionText.isEmpty {
                            Text(singleLine(task.descriptionText))
                                .font(.system(size: 10))
                                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    // Keeps long titles clear of the copy / pin buttons.
                    .padding(.trailing, 56)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // With a date, the chips give way (project first, then state,
                    // then priority) so the date always fits. Without one they
                    // keep their natural size.
                    let dateText = formattedTargetDate(task.targetDate)
                    HStack(spacing: 6) {
                        priorityChip(task.priority)
                            .fixedSize(horizontal: dateText == nil, vertical: false)
                            .layoutPriority(2)
                        stateChip(task)
                            .fixedSize(horizontal: dateText == nil, vertical: false)
                            .layoutPriority(1)
                        projectChip(task.project)
                        Spacer(minLength: 8)
                        if let date = dateText {
                            HStack(spacing: 4) {
                                Image(systemName: "calendar.badge.clock")
                                    .font(.system(size: 10, weight: .regular))
                                Text(date)
                                    .font(.system(size: 11, weight: .regular))
                            }
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            .lineLimit(1)
                            .fixedSize()
                            .layoutPriority(3)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("Show task details")

            HStack(spacing: 6) {
                copyRowButton(task)
                pinRowButton(task)
            }
            .padding(.top, 12)
            .padding(.trailing, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AdaptiveColors.notchSurfaceCardFill, in: shape)
        .contentShape(shape)
    }

    /// Placeholder row. The bars use a tint that contrasts with the card
    /// fill (the old version drew card-fill on card-fill, so it was nearly
    /// invisible). The shimmer is applied once to the whole list.
    private func taskSkeletonRow(index: Int) -> some View {
        let bar = AdaptiveColors.notchSurfaceTertiaryText.opacity(0.28)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(bar)
                    .frame(width: index.isMultiple(of: 2) ? 42 : 52, height: 7)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(bar)
                    .frame(width: 62, height: 7)
                Spacer(minLength: 0)
            }

            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(bar)
                .frame(width: index == 1 ? 220 : 180, height: 10)

            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(bar)
                .frame(width: 260, height: 7)

            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: DroppyRadius.full, style: .continuous)
                    .fill(bar)
                    .frame(width: 46, height: 22)
                RoundedRectangle(cornerRadius: DroppyRadius.full, style: .continuous)
                    .fill(bar)
                    .frame(width: index == 2 ? 88 : 74, height: 22)
                RoundedRectangle(cornerRadius: DroppyRadius.full, style: .continuous)
                    .fill(bar)
                    .frame(width: 72, height: 22)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AdaptiveColors.notchSurfaceCardFill,
            in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
        )
    }

    private func pinRowButton(_ task: PlaneTask) -> some View {
        let isPinned = droplet.pinnedIDs.contains(task.id)
        return Button {
            withAnimation(.snappy(duration: 0.2)) { droplet.togglePin(task) }
        } label: {
            Image(systemName: "pin.fill")
                .font(.system(size: 9.5, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(isPinned ? Color.blue : AdaptiveColors.notchSurfaceSecondaryText)
        }
        .buttonStyle(DroppyCircleButtonStyle(size: 20))
        .help(isPinned ? "Unpin task" : "Pin task")
        .accessibilityLabel(isPinned ? "Unpin task" : "Pin task")
    }

    private func copyRowButton(_ task: PlaneTask) -> some View {
        Button {
            copyToPasteboard(task.reference, feedbackKey: "row-id-\(task.id)")
        } label: {
            Image(systemName: copiedFeedback == "row-id-\(task.id)" ? "checkmark" : "doc.on.doc")
                .font(.system(size: 9.5, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(
                    copiedFeedback == "row-id-\(task.id)"
                        ? Color.green
                        : AdaptiveColors.notchSurfaceSecondaryText
                )
        }
        .buttonStyle(DroppyCircleButtonStyle(size: 20))
        .help(copiedFeedback == "row-id-\(task.id)" ? "Copied" : "Copy task ID")
        .accessibilityLabel("Copy task ID")
    }

    private func showCopiedFeedback(_ key: String) {
        withAnimation(DroppyAnimation.bounce) {
            copiedFeedback = key
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(.easeOut(duration: 0.2)) {
                if copiedFeedback == key {
                    copiedFeedback = nil
                }
            }
        }
    }

    private func copyToPasteboard(_ value: String, feedbackKey: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        showCopiedFeedback(feedbackKey)
    }

    private func errorBox(_ message: String) -> some View {
        HStack(alignment: .top, spacing: DroppySpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.orange)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn’t load Plane")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)

                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button {
                droplet.refresh()
            } label: {
                Image(systemName: droplet.isRefreshing ? "arrow.clockwise" : "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(DroppyCircleButtonStyle(size: 18))
            .disabled(droplet.isRefreshing)
            .help("Try again")
        }
        .padding(DroppySpacing.sm)
        .background(
            Color.orange.opacity(0.10),
            in: RoundedRectangle(cornerRadius: DroppyRadius.medium, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: DroppyRadius.medium, style: .continuous)
                .stroke(Color.orange.opacity(0.22), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Couldn’t load Plane: \(message)")
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoPlain = ISO8601DateFormatter()
    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
    private static let targetDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    private func formattedTargetDate(_ rawDate: String?) -> String? {
        guard let rawDate, !rawDate.isEmpty else { return nil }
        let date = Self.isoWithFraction.date(from: rawDate)
            ?? Self.isoPlain.date(from: rawDate)
            ?? Self.dateOnlyFormatter.date(from: String(rawDate.prefix(10)))
        guard let date else { return rawDate }
        return Self.targetDateFormatter.string(from: date)
    }

    private func priorityStyle(_ priority: String) -> (label: String, tint: Color, level: Double) {
        switch priority.lowercased() {
        case "urgent": return ("Urgent", .purple, 1.0)
        case "high": return ("High", .red, 0.75)
        case "medium": return ("Medium", .orange, 0.5)
        case "low": return ("Low", .green, 0.25)
        default: return ("No priority", AdaptiveColors.notchSurfaceTertiaryText, 0)
        }
    }

    /// Priority uses the SF Symbol `cellularbars` with a variable value,
    /// so the bars fill up with the priority level.
    private func priorityChip(_ priority: String, iconOnly: Bool = false) -> some View {
        let style = priorityStyle(priority)

        return HStack(spacing: 5) {
            Image(systemName: "cellularbars", variableValue: style.level)
                .font(.system(size: 10, weight: .semibold))

            if !iconOnly {
                Text(style.label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(style.tint)
        .padding(.horizontal, iconOnly ? 8 : 10)
        .padding(.vertical, 5)
        .background(style.tint.opacity(0.16), in: Capsule(style: .continuous))
        .help("Priority: \(style.label)")
    }

    private func stateChip(_ task: PlaneTask) -> some View {
        let tint = groupColor(task.stateGroup)

        return HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)

            Text(task.status)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.10), in: Capsule(style: .continuous))
        .help("State: \(task.status)")
    }

    private func projectChip(_ project: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "folder.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            Text(project)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.10), in: Capsule(style: .continuous))
        .help("Project: \(project)")
    }

    private var canScrollDetailUp: Bool { detailOffsetY > 1 }
    private var canScrollDetailDown: Bool { (detailContentHeight - detailViewportHeight - detailOffsetY) > 1 }

    private func detailScreen(_ task: PlaneTask) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: DroppySpacing.sm) {
                Button {
                    closeDetails()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(DroppyCircleButtonStyle(size: 20))
                .help("Back to tasks")
                .accessibilityLabel("Back to tasks")

                Text("Plane Tasks")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                Spacer(minLength: 0)
                detailActionGroup(task)
            }
            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)

            // The header stays put; properties, title and description scroll
            // together, with the same edge fade as the list.
            ScrollView(.vertical) {
                detailView(task)
                    .padding(.bottom, 24)
                    .background {
                        ScrollViewScrollerHider()
                            .frame(width: 0, height: 0)
                    }
            }
            .id(task.id)
            .scrollIndicators(.hidden, axes: .vertical)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { _, newValue in
                detailOffsetY = newValue
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height
            } action: { _, newValue in
                detailContentHeight = newValue
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.containerSize.height
            } action: { _, newValue in
                detailViewportHeight = newValue
            }
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [.clear, .black],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: canScrollDetailUp ? 28 : 0)

                    Color.black

                    LinearGradient(
                        colors: [.black, .clear],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: canScrollDetailDown ? 28 : 0)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: canScrollDetailUp)
            .animation(.easeInOut(duration: 0.15), value: canScrollDetailDown)
        }
    }

    private func detailView(_ task: PlaneTask) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Properties")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)

                VStack(alignment: .leading, spacing: 8) {
                    propertyRow(symbol: "circle.dotted.circle", title: "State") {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(groupColor(task.stateGroup))
                                .frame(width: 7, height: 7)
                            Text(task.status)
                                .lineLimit(1)
                        }
                    }
                    propertyRow(symbol: "cellularbars", title: "Priority") {
                        priorityChip(task.priority)
                    }
                    propertyRow(symbol: "calendar.badge.clock", title: "Start Date") {
                        Text(formattedTargetDate(task.startDate) ?? "—")
                    }
                    propertyRow(symbol: "calendar.badge.checkmark", title: "Due Date") {
                        Text(formattedTargetDate(task.targetDate) ?? "—")
                    }
                    propertyRow(symbol: "folder", title: "Project") {
                        Text(task.project)
                            .lineLimit(1)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(task.reference.uppercased())
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                Text(task.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if task.descriptionText.isEmpty {
                    Text("No description available.")
                        .font(.system(size: 10))
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                } else {
                    // The web view is sized to its content, so the outer
                    // ScrollView (not the web view) does the scrolling.
                    RichDescriptionView(
                        html: task.descriptionHTML,
                        fallbackText: task.descriptionText,
                        contentHeight: $descriptionHeight
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: max(descriptionHeight, 24))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One "Properties" line: SF Symbol + label on the left, value in a fixed column.
    private func propertyRow<Value: View>(symbol: String, title: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .regular))
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            .frame(width: 112, alignment: .leading)

            value()
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)

            Spacer(minLength: 0)
        }
        .frame(minHeight: 18)
    }

    /// Plane stores descriptions as HTML. AppKit's NSTextView is used here
    /// instead of a browser view so rich text is laid out by native macOS
    /// text rendering: wrapping, lists, emphasis, links, code and tables.
    /// Plane stores the description as Tiptap HTML. Use WebKit here because
    /// Plane itself renders this same HTML model in a browser/editor. This
    /// keeps headings, paragraphs, emphasis, links, lists, checklists, tables,
    /// code, images and text alignment instead of flattening them through an
    /// attributed-string HTML importer.
    private struct RichDescriptionView: NSViewRepresentable {
        let html: String?
        let fallbackText: String
        @Binding var contentHeight: CGFloat

        func makeNSView(context: Context) -> WKWebView {
            let configuration = WKWebViewConfiguration()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false

            let webView = PassthroughWebView(frame: .zero, configuration: configuration)
            webView.setValue(false, forKey: "drawsBackground")
            webView.allowsMagnification = false
            webView.navigationDelegate = context.coordinator
            webView.layer?.backgroundColor = NSColor.clear.cgColor
            return webView
        }

        func updateNSView(_ webView: WKWebView, context: Context) {
            let heightBinding = $contentHeight
            context.coordinator.onHeight = { height in
                if abs(heightBinding.wrappedValue - height) > 0.5 { heightBinding.wrappedValue = height }
            }
            let source = html?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let body = source.isEmpty ? fallbackText : source
            let document = Self.document(body: body)

            guard context.coordinator.lastDocument != document else { return }
            context.coordinator.lastDocument = document
            webView.loadHTMLString(document, baseURL: nil)
        }

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        private static func escapeHTML(_ value: String) -> String {
            value
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&#39;")
        }

        private static func document(body: String) -> String {
            let renderedBody: String

            if body.contains("<") && body.contains(">") {
                renderedBody = body
            } else {
                renderedBody = escapeHTML(body).replacingOccurrences(of: "\n", with: "<br>")
            }

            return """
            <!doctype html>
            <html>
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0">
              <style>
                :root {
                  color-scheme: dark;
                  --text: rgba(255,255,255,.78);
                  --heading: rgba(255,255,255,.96);
                  --muted: rgba(255,255,255,.62);
                  --link: #5AA7FF;
                  --code: rgba(255,255,255,.07);
                  --border: rgba(255,255,255,.11);
                  --checkbox: #5AA7FF;
                }

                * { box-sizing: border-box; }

                html, body {
                  margin: 0;
                  padding: 0;
                  background: transparent;
                  color: var(--text);
                  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
                  font-size: 10.5px;
                  line-height: 1.5;
                  overflow: hidden;
                  -webkit-font-smoothing: antialiased;
                }

                body {
                  padding: 2px;
                  overflow-wrap: anywhere;
                  word-break: break-word;
                }

                ::-webkit-scrollbar { width: 0; height: 0; }
                ::-webkit-scrollbar-thumb,
                ::-webkit-scrollbar-track { background: transparent; }

                p { margin: 0 0 9px; }
                p:last-child { margin-bottom: 0; }

                h1, h2, h3, h4, h5, h6 {
                  color: var(--heading);
                  line-height: 1.25;
                  font-weight: 700;
                  margin: 14px 0 7px;
                }
                h1:first-child, h2:first-child, h3:first-child,
                h4:first-child, h5:first-child, h6:first-child {
                  margin-top: 2px;
                }
                h1 { font-size: 20px; }
                h2 { font-size: 17px; }
                h3 { font-size: 14px; }
                h4 { font-size: 13px; }
                h5, h6 { font-size: 12px; }

                strong, b { color: var(--heading); font-weight: 700; }
                em, i { font-style: italic; }
                u { text-decoration: underline; }
                s, del { opacity: .65; }

                a {
                  color: var(--link);
                  text-decoration: underline;
                  text-decoration-thickness: .5px;
                  text-underline-offset: 2px;
                }

                /* Plane/Tiptap normal lists. */
                ul:not([data-type="taskList"]),
                ol {
                  margin: 5px 0 10px;
                  padding-left: 22px;
                }
                ul:not([data-type="taskList"]) li,
                ol li {
                  margin: 3px 0;
                  padding-left: 2px;
                }
                ul:not([data-type="taskList"]) ul,
                ul:not([data-type="taskList"]) ol,
                ol ul,
                ol ol {
                  margin-top: 3px;
                  margin-bottom: 3px;
                }

                /* Plane/Tiptap checklists: NEVER give task items a list marker. */
                ul[data-type="taskList"] {
                  list-style: none !important;
                  margin: 5px 0 10px !important;
                  padding: 0 !important;
                }

                ul[data-type="taskList"] > li[data-type="taskItem"],
                li[data-type="taskItem"] {
                  list-style: none !important;
                  display: flex;
                  align-items: flex-start;
                  gap: 6px;
                  margin: 4px 0;
                  padding: 0 !important;
                }

                li[data-type="taskItem"]::marker,
                ul[data-type="taskList"] > li::marker {
                  content: "" !important;
                  font-size: 0 !important;
                }

                li[data-type="taskItem"] > label {
                  flex: 0 0 auto;
                  display: flex;
                  align-items: center;
                  margin-top: 2px;
                }

                li[data-type="taskItem"] > label > input[type="checkbox"] {
                  appearance: none;
                  -webkit-appearance: none;
                  width: 13px;
                  height: 13px;
                  margin: 0;
                  border: 1.5px solid rgba(255,255,255,.38);
                  border-radius: 3px;
                  background: transparent;
                  position: relative;
                }

                li[data-type="taskItem"] > label > input[type="checkbox"]:checked {
                  background: var(--checkbox);
                  border-color: var(--checkbox);
                }

                li[data-type="taskItem"] > label > input[type="checkbox"]:checked::after {
                  content: "";
                  position: absolute;
                  left: 3px;
                  top: 0px;
                  width: 4px;
                  height: 8px;
                  border: solid white;
                  border-width: 0 1.5px 1.5px 0;
                  transform: rotate(45deg);
                }

                li[data-type="taskItem"] > div {
                  flex: 1 1 auto;
                  min-width: 0;
                }

                li[data-type="taskItem"] > div > p:last-child {
                  margin-bottom: 0;
                }

                /* Nested task lists remain checklists, never bullets. */
                li[data-type="taskItem"] ul[data-type="taskList"] {
                  margin: 4px 0 4px 0 !important;
                  padding-left: 0 !important;
                }

                blockquote {
                  margin: 9px 0;
                  padding: 7px 10px;
                  border-left: 3px solid rgba(255,255,255,.22);
                  color: var(--muted);
                  background: rgba(255,255,255,.035);
                  border-radius: 4px;
                }

                pre {
                  margin: 9px 0;
                  padding: 9px 10px;
                  background: var(--code);
                  border-radius: 7px;
                  overflow-x: auto;
                  white-space: pre-wrap;
                  font: 11px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace;
                }

                code {
                  padding: 1px 4px;
                  border-radius: 4px;
                  background: var(--code);
                  font: 11px ui-monospace, SFMono-Regular, Menlo, monospace;
                }
                pre code { padding: 0; background: transparent; }

                hr {
                  border: 0;
                  border-top: 1px solid var(--border);
                  margin: 12px 0;
                }

                table {
                  width: 100%;
                  border-collapse: collapse;
                  margin: 9px 0 12px;
                  font-size: 11px;
                }
                th, td {
                  border: 1px solid var(--border);
                  padding: 6px 7px;
                  text-align: left;
                  vertical-align: top;
                }
                th {
                  color: rgba(255,255,255,.94);
                  background: rgba(255,255,255,.055);
                  font-weight: 650;
                }

                img {
                  display: block;
                  max-width: 100%;
                  height: auto;
                  border-radius: 7px;
                }

                [style*="text-align: center"] { text-align: center !important; }
                [style*="text-align: right"] { text-align: right !important; }
                [style*="text-align: justify"] { text-align: justify !important; }

                mark {
                  background: rgba(255, 210, 60, .35);
                  color: inherit;
                  border-radius: 2px;
                }

                .mention {
                  color: var(--link);
                }
              </style>
            </head>
            <body>
              \(renderedBody)
            </body>
            </html>
            """
        }

        @MainActor
        final class Coordinator: NSObject, WKNavigationDelegate {
            var lastDocument = ""
            var onHeight: ((CGFloat) -> Void)?

            func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
                measure(webView)
                // Fonts and images can settle a moment after didFinish.
                Task { [weak self, weak webView] in
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self, let webView else { return }
                    self.measure(webView)
                }
            }

            private func measure(_ webView: WKWebView) {
                webView.evaluateJavaScript("Math.ceil(document.body.getBoundingClientRect().height)") { [weak self] result, _ in
                    guard let height = (result as? NSNumber)?.doubleValue else { return }
                    self?.onHeight?(CGFloat(height))
                }
            }

            func webView(
                _ webView: WKWebView,
                decidePolicyFor navigationAction: WKNavigationAction,
                decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
            ) {
                if navigationAction.navigationType == .linkActivated,
                   let url = navigationAction.request.url {
                    NSWorkspace.shared.open(url)
                    decisionHandler(.cancel)
                } else {
                    decisionHandler(.allow)
                }
            }
        }
    }

    private func detailActionGroup(_ task: PlaneTask) -> some View {
        HStack(spacing: 6) {
            detailIconButton(
                symbol: copiedFeedback == "detail-id-\(task.id)" ? "checkmark" : "doc.on.doc",
                isCopied: copiedFeedback == "detail-id-\(task.id)",
                help: "Copy ID",
                action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(task.reference, forType: .string)
                    showCopiedFeedback("detail-id-\(task.id)")
                }
            )
            detailIconButton(
                symbol: copiedFeedback == "detail-link-\(task.id)" ? "checkmark" : "link",
                isCopied: copiedFeedback == "detail-link-\(task.id)",
                help: "Copy link",
                action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(task.webURL.absoluteString, forType: .string)
                    showCopiedFeedback("detail-link-\(task.id)")
                }
            )
            detailIconButton(
                symbol: "arrow.up.forward.app",
                help: "Open in browser",
                action: {
                    NSWorkspace.shared.open(task.webURL)
                }
            )
        }
    }

    private func closeDetails() {
        withAnimation(DroppyAnimation.panelSlide) {
            isShowingDetail = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard !isShowingDetail else { return }
            detailTask = nil
            droplet.selectedTaskID = nil
        }
    }

    /// `panelSlide` animates the position of an already-mounted panel. Mount
    /// the detail page first at its offscreen position, then change the slide
    /// state on the following run-loop turn. Mounting it and moving it in the
    /// same transaction skips the starting position, which reads as a cut.
    private func showDetails(for task: PlaneTask) {
        withTransaction(Transaction(animation: nil)) {
            detailTask = task
            droplet.selectedTaskID = task.id
            isShowingDetail = false
            detailOffsetY = 0
            detailContentHeight = 0
            detailViewportHeight = 0
            descriptionHeight = 0
        }

        DispatchQueue.main.async {
            withAnimation(DroppyAnimation.panelSlide) {
                isShowingDetail = true
            }
        }
    }

    private func detailIconButton(
        symbol: String,
        isCopied: Bool = false,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(isCopied ? Color.green : AdaptiveColors.notchSurfaceSecondaryText)
        }
        .buttonStyle(DroppyCircleButtonStyle(size: 20))
        .help(help)
    }

}


/// A soft highlight that sweeps across placeholder content, like the system
/// loading shimmer. Driven by TimelineView so it keeps animating inside a
/// hosted view, and it stays still when Reduce Motion is on.
private struct ShimmerModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let period: Double = 1.5

    func body(content: Content) -> some View {
        if reduceMotion {
            content.opacity(0.7)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: period) / period
                content.mask {
                    ZStack {
                        Color.black.opacity(0.45)
                        GeometryReader { proxy in
                            let band = max(proxy.size.width * 0.4, 80)
                            LinearGradient(
                                colors: [.clear, .black, .clear],
                                startPoint: .leading, endPoint: .trailing
                            )
                            .frame(width: band, height: proxy.size.height)
                            .offset(x: -band + phase * (proxy.size.width + band))
                        }
                    }
                }
            }
        }
    }
}

private extension View {
    func shimmering() -> some View { modifier(ShimmerModifier()) }
}

/// Web view that never scrolls on its own: wheel / trackpad events go to the
/// enclosing SwiftUI ScrollView, so the whole detail page scrolls together.
private final class PassthroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

/// One row of the project menu: checkmark column, accent highlight on hover,
/// the way an NSMenu item looks.
private struct ProjectMenuRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 12)
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isHovering ? Color.white : Color.primary)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.accentColor.opacity(isHovering ? 1 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// Explicitly removes AppKit scrollbars from SwiftUI ScrollViews while
/// preserving trackpad/mouse-wheel scrolling. SwiftUI's .scrollIndicators(.hidden)
/// alone can still leave overlay scrollers visible in hosted macOS views.
private struct ScrollViewScrollerHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = false
        DispatchQueue.main.async { hideEnclosingScrollers(from: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { hideEnclosingScrollers(from: nsView) }
    }

    private func hideEnclosingScrollers(from view: NSView) {
        if let scrollView = view.enclosingScrollView {
            hide(scrollView)
            return
        }
        var ancestor = view.superview
        while let current = ancestor {
            if let scrollView = current as? NSScrollView {
                hide(scrollView)
                return
            }
            ancestor = current.superview
        }
    }

    private func hide(_ scrollView: NSScrollView) {
        scrollView.scrollerStyle = .overlay
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
    }
}

/// A text field that keeps its own local draft while typing and only writes
/// back to `committedValue` when the person presses Enter or clicks away,
/// instead of on every keystroke.
private struct CommitField: View {
    let prompt: String
    var isSecure: Bool = false
    @Binding var committedValue: String

    @State private var draft: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if isSecure {
                SecureField("", text: $draft, prompt: Text(prompt))
            } else {
                TextField("", text: $draft, prompt: Text(prompt))
            }
        }
        .textFieldStyle(.roundedBorder)
        .frame(width: 220)
        .focused($isFocused)
        .onAppear { draft = committedValue }
        .onSubmit {
            commit()
            isFocused = false
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { commit() }
        }
    }

    private func commit() {
        if draft != committedValue { committedValue = draft }
    }
}

private struct PlaneTasksSettings: View {
    @ObservedObject var droplet: PlaneTasksDroplet

    var body: some View {
        let _ = droplet.settingsRevision

        DropletSettingsPane {
            DropletSettingsSection {
                numberedSectionHeader("1", "Connect your Plane account")
            } content: {
                DropletSettingsCard {
                    DropletControlRow(
                        title: "Workspace slug",
                        infoTip: "Find the workspace slug in your Plane URL."
                    ) {
                        CommitField(prompt: "your-workspace", committedValue: droplet.workspaceBinding)
                    }
                    DropletControlRow(
                        title: "Personal access token",
                        infoTip: "Create a personal API token in your Plane account settings."
                    ) {
                        CommitField(prompt: "plane_api_…", isSecure: true, committedValue: droplet.tokenBinding)
                    }
                }
            }

            DropletSettingsSection {
                numberedSectionHeader("2", "API URL")
            } content: {
                DropletSettingsCard {
                    DropletControlRow(
                        title: "Plane API URL",
                        infoTip: "For the default Plane Cloud URL (app.plane.so), use https://api.plane.so here."
                    ) {
                        CommitField(prompt: "https://api.plane.so", committedValue: droplet.baseURLBinding)
                    }
                }
            }

            DropletSettingsSection {
                numberedSectionHeader("3", "Connection")
            } content: {
                DropletSettingsCard {
                    DropletControlRow(
                        title: "Status",
                        infoTip: "Shows whether Plane accepted your workspace and token the last time it was checked."
                    ) {
                        statusChip(droplet.connectionStatus)
                    }
                    if case .failed(let message) = droplet.connectionStatus {
                        DropletControlRow(title: "Details") {
                            Text(message)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: 240, alignment: .trailing)
                        }
                    }
                    DropletControlRow(title: "Refresh") {
                        Button("Refresh") {
                            droplet.refresh()
                        }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                        .disabled(!droplet.isConfigured)
                    }
                }
            }

            DropletSettingsSection {
                numberedSectionHeader("4", "New task alerts")
            } content: {
                DropletSettingsCard {
                    DropletToggleRow(
                        title: "Notify about new tasks",
                        subtitle: "Shows an alert beside the notch and a badge on the All tab.",
                        isOn: droplet.notifyBinding
                    )
                    DropletControlRow(title: "Check every") {
                        Picker("Check every", selection: droplet.pollMinutesBinding) {
                            ForEach([1, 5, 10, 15, 30], id: \.self) { Text("\($0) min").tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(!droplet.notifyBinding.wrappedValue)
                    }
                    DropletControlRow(title: "Alert duration") {
                        Picker("Alert duration", selection: droplet.alertSecondsBinding) {
                            ForEach([3, 5, 10, 15], id: \.self) { Text("\($0) s").tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(!droplet.notifyBinding.wrappedValue)
                    }
                }
            }
        }
    }

    /// A section header with a numbered SF Symbol circle in front of it,
    /// e.g. "1.circle.fill". Native, vector, no hand-drawn shapes.
    private func numberedSectionHeader(_ number: String, _ title: String) -> some View {
        HStack(spacing: DroppySpacing.xs) {
            Image(systemName: "\(number).circle.fill")
                .foregroundStyle(.blue)
                .font(.system(size: 14))
            settingsSectionHeader(LocalizedStringKey(title))
        }
    }

    /// Status chip driven by the real result of the last request: green only
    /// when Plane accepted the credentials, orange while setup is missing or
    /// the request failed, neutral while checking. Plain tinted pill, no dot.
    @ViewBuilder
    private func statusChip(_ status: ConnectionStatus) -> some View {
        switch status {
        case .needsSetup:
            chipLabel("Needs setup", color: .orange)
        case .checking:
            HStack(spacing: DroppySpacing.xsm) {
                ProgressView().controlSize(.mini)
                Text("Checking…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        case .connected:
            chipLabel("Ready", color: .green)
        case .failed:
            chipLabel("Can’t connect", color: .red)
        }
    }

    private func chipLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, DroppySpacing.sm)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule(style: .continuous))
    }
}

fileprivate enum LoadState: Equatable { case needsSetup, loading, loaded, failed(String) }
fileprivate enum ConnectionStatus: Equatable { case needsSetup, checking, connected, failed(String) }
fileprivate enum ListTab: Hashable { case all, pinned }
private struct PlaneUser: Decodable {
    let id: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        if let directID = try? container.decode(String.self, forKey: .id) {
            id = directID
            return
        }

        // Plane may wrap the current-user object in "data" or "user".
        if let nested = try? container.decode(PlaneUser.self, forKey: .data) {
            id = nested.id
            return
        }
        if let nested = try? container.decode(PlaneUser.self, forKey: .user) {
            id = nested.id
            return
        }

        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath,
                  debugDescription: "Plane user response did not contain a string id.")
        )
    }

    private enum Keys: String, CodingKey { case id, data, user }
}

private struct PlaneProject: Decodable {
    let id: String
    let identifier: String?
    let name: String?

    enum CodingKeys: String, CodingKey { case id, identifier, name }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        identifier = try? container.decodeIfPresent(String.self, forKey: .identifier)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
    }
}

private struct PlaneState: Decodable {
    let id: String?
    let name: String?
    let group: String?

    enum CodingKeys: String, CodingKey { case id, name, group }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            id = nil
            name = nil
            group = nil
            return
        }
        id = try? container.decodeIfPresent(String.self, forKey: .id)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        group = try? container.decodeIfPresent(String.self, forKey: .group)
    }
}

private struct PlaneStateDefinition: Decodable {
    let id: String
    let name: String
    let group: String?

    enum CodingKeys: String, CodingKey { case id, name, group }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = (try? container.decode(String.self, forKey: .name)) ?? "Unnamed status"
        group = try? container.decodeIfPresent(String.self, forKey: .group)
    }
}

private struct PlaneWorkItem: Decodable {
    let id: String
    let name: String
    let descriptionHTML: String?
    let description: String?
    let priority: String?
    let sequenceID: Int
    let targetDate: String?
    let startDate: String?
    let createdAt: String?
    let state: PlaneState?
    let stateID: String?
    let assigneeIDs: [String]

    enum CodingKeys: String, CodingKey {
        case id, name, priority, state, assignees, description
        case descriptionHTML = "description_html"
        case sequenceID = "sequence_id"
        case targetDate = "target_date"
        case startDate = "start_date"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = (try? container.decode(String.self, forKey: .name)) ?? "Untitled task"

        // These fields vary across Plane API versions. Ignore them if the
        // server returns a non-string value rather than failing the whole task.
        descriptionHTML = Self.decodeFlexibleText(container, key: .descriptionHTML)
        description = Self.decodeFlexibleText(container, key: .description)
        priority = try? container.decodeIfPresent(String.self, forKey: .priority)
        sequenceID = (try? container.decode(Int.self, forKey: .sequenceID)) ?? 0
        targetDate = try? container.decodeIfPresent(String.self, forKey: .targetDate)
        startDate = try? container.decodeIfPresent(String.self, forKey: .startDate)
        createdAt = try? container.decodeIfPresent(String.self, forKey: .createdAt)
        state = try? container.decodeIfPresent(PlaneState.self, forKey: .state)
        stateID = (try? container.decodeIfPresent(String.self, forKey: .state)) ?? state?.id

        if let users = try? container.decode([PlaneUser].self, forKey: .assignees) {
            assigneeIDs = users.map(\.id)
        } else if let ids = try? container.decode([String].self, forKey: .assignees) {
            assigneeIDs = ids
        } else {
            assigneeIDs = []
        }
    }

    private static func decodeFlexibleText(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> String? {
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent([String].self, forKey: key) {
            return value.joined(separator: "\n")
        }
        // Do not fail task loading because a description field has an
        // unexpected object/array representation in a particular API version.
        return nil
    }
}
private struct PlanePage<Value: Decodable>: Decodable {
    let results: [Value]
    init(from decoder: Decoder) throws {
        if var list = try? decoder.unkeyedContainer() { var values: [Value] = []; while !list.isAtEnd { values.append(try list.decode(Value.self)) }; results = values; return }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        results = try container.decodeIfPresent([Value].self, forKey: .results) ?? container.decodeIfPresent([Value].self, forKey: .data) ?? []
    }
    private enum CodingKeys: String, CodingKey { case results, data }
}
fileprivate struct PlaneTask: Identifiable {
    let id: String; let name: String; let reference: String; let targetDate: String?; let startDate: String?; let createdAt: String?
    let priority: String; let status: String; let stateGroup: String; let descriptionText: String; let descriptionHTML: String?
    let project: String; let webURL: URL
    var priorityColor: Color { switch priority { case "urgent": .red; case "high": .orange; case "medium": .yellow; default: .secondary } }
}
private struct PlaneClient: Sendable {
    let baseURL: URL; let webBaseURL: URL; let workspace: String; let token: String
    func currentUser() async throws -> PlaneUser { try await get("/api/v1/users/me/") }
    func projects() async throws -> [PlaneProject] { try await page("/api/v1/workspaces/\(workspace)/projects/?per_page=100") }
    func states(in project: PlaneProject) async -> [String: PlaneStateDefinition] {
        let path = "/api/v1/workspaces/\(workspace)/projects/\(project.id)/states/?per_page=100"
        if let values: [PlaneStateDefinition] = try? await page(path) {
            return Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
        }
        return [:]
    }

    func tasks(in project: PlaneProject, assignedTo userID: String) async throws -> [PlaneTask] {
        let stateLookup = await states(in: project)
        let workItemsPath = "/api/v1/workspaces/\(workspace)/projects/\(project.id)/work-items/?per_page=100&expand=assignees"
        let items: [PlaneWorkItem]
        do { items = try await page(workItemsPath) }
        catch PlaneError.response(let code) where code == 404 {
            items = try await page("/api/v1/workspaces/\(workspace)/projects/\(project.id)/issues/?per_page=100&expand=assignees")
        }
        catch PlaneError.response(let code) where code == 403 { return [] }
        return items.filter { $0.assigneeIDs.contains(userID) }.compactMap { item in
            let resolvedStatus = item.state?.name ?? item.stateID.flatMap { stateLookup[$0]?.name }
            let resolvedGroup = item.state?.group ?? item.stateID.flatMap { stateLookup[$0]?.group } ?? ""
            let reference = "\(project.identifier ?? project.id)-\(item.sequenceID)"
            guard let url = URL(string: "/\(workspace)/browse/\(reference)", relativeTo: webBaseURL) else { return nil }
            let rawDescription = item.descriptionHTML ?? item.description ?? ""
            let plainDescription = rawDescription
                .replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
                .replacingOccurrences(of: "(?i)</p>|</div>|</li>", with: "\n", options: .regularExpression)
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return PlaneTask(id: item.id, name: item.name, reference: reference, targetDate: item.targetDate, startDate: item.startDate, createdAt: item.createdAt,
                             priority: item.priority ?? "none", status: resolvedStatus ?? "Unknown",
                             stateGroup: resolvedGroup, descriptionText: plainDescription, descriptionHTML: item.descriptionHTML,
                             project: Self.projectDisplayName(project), webURL: url)
        }
    }
    private static func projectDisplayName(_ project: PlaneProject) -> String {
        let name = project.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let identifier = project.identifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty && !identifier.isEmpty { return "\(name) (\(identifier))" }
        if !name.isEmpty { return name }
        if !identifier.isEmpty { return identifier }
        return "Project"
    }

    private func page<Value: Decodable>(_ path: String) async throws -> [Value] { try await get(path, as: PlanePage<Value>.self).results }
    private func get<Value: Decodable>(_ path: String, as: Value.Type = Value.self) async throws -> Value {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw URLError(.badURL) }
        var request = URLRequest(url: url); request.setValue(token, forHTTPHeaderField: "X-API-Key")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw PlaneError.response((response as? HTTPURLResponse)?.statusCode) }
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch let error as DecodingError {
            let detail: String
            switch error {
            case .keyNotFound(let key, let context):
                detail = "Missing field '\(key.stringValue)' at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
            case .typeMismatch(let type, let context):
                detail = "Expected \(type) at \(context.codingPath.map(\.stringValue).joined(separator: ".")): \(context.debugDescription)"
            case .valueNotFound(let type, let context):
                detail = "Missing value for \(type) at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
            case .dataCorrupted(let context):
                detail = "Invalid data at \(context.codingPath.map(\.stringValue).joined(separator: ".")): \(context.debugDescription)"
            @unknown default:
                detail = error.localizedDescription
            }
            throw PlaneError.decoding(detail)
        }
    }
}
private enum PlaneError: LocalizedError { case response(Int?); case decoding(String); var errorDescription: String? { switch self { case .response(let code): return "Plane returned \(code ?? 0). Check the token and workspace slug."; case .decoding(let detail): return "Plane response format issue: \(detail)" } } }
private final class TokenStore {
    private let service: String; init(service: String) { self.service = service }
    func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "personal-access-token", kSecReturnData as String: true]
        var result: CFTypeRef?; guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }; return String(data: data, encoding: .utf8)
    }
    func write(_ token: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "personal-access-token"]
        if token.isEmpty { SecItemDelete(query as CFDictionary); return }
        let data = Data(token.utf8); let update = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound { var add = query; add[kSecValueData as String] = data; SecItemAdd(add as CFDictionary, nil) }
    }
}
