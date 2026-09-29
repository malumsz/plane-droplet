import AppKit
import Combine
import DroppyKit
import Foundation
import Security
import SwiftUI

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
    private var host: DropletHost?
    private var reloadTask: Task<Void, Never>?
    private let tokenStore = TokenStore(service: "app.getdroppy.plane-tasks")
    
    public func activate(host: DropletHost) throws { self.host = host; host.log.info("Plane Tasks activated"); refresh() }
    public func deactivate() { reloadTask?.cancel(); reloadTask = nil; host = nil }
    public func refresh() { reloadTask?.cancel(); reloadTask = Task { [weak self] in await self?.loadTasks() } }

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
    fileprivate var visibleTasks: [PlaneTask] {
        tasks.filter { task in
            let statusMatches = selectedStatuses.isEmpty
                || (selectedProject == "All" ? selectedStatuses.contains(task.stateGroup) : selectedStatuses.contains(task.status))
            return statusMatches
            && (selectedProject == "All" || task.project == selectedProject)
            && (searchText.isEmpty || task.name.localizedCaseInsensitiveContains(searchText) || task.reference.localizedCaseInsensitiveContains(searchText) || task.project.localizedCaseInsensitiveContains(searchText))
        }.sorted {
            ($0.targetDate ?? "9999-12-31", $0.name) < ($1.targetDate ?? "9999-12-31", $1.name)
        }
    }
    fileprivate var selectedTask: PlaneTask? { tasks.first { $0.id == selectedTaskID } }

    private func loadTasks() async {
        guard !workspace.isEmpty, let token = tokenStore.read(), !token.isEmpty else { state = .needsSetup; tasks = []; return }
        guard let base = URL(string: baseURL) else { state = .failed("The Plane URL is invalid."); return }
        state = .loading
        do {
            let webBaseURL = base.host == "api.plane.so" ? URL(string: "https://app.plane.so")! : base
            let client = PlaneClient(baseURL: base, webBaseURL: webBaseURL, workspace: workspace, token: token)
            let currentUser = try await client.currentUser()
            let projects = try await client.projects()
            let lists = try await withThrowingTaskGroup(of: [PlaneTask].self) { group in
                for project in projects { group.addTask { try await client.tasks(in: project, assignedTo: currentUser.id) } }
                var all: [PlaneTask] = []; for try await list in group { all += list }; return all
            }
            tasks = lists
            state = .loaded
            host?.log.info("Plane Tasks loaded \(tasks.count) assigned tasks")
        } catch is CancellationError { return
        } catch { tasks = []; state = .failed(error.localizedDescription); host?.log.error("Plane Tasks request failed: \(error.localizedDescription)") }
    }

    var workspaceBinding: Binding<String> {
        Binding(
            get: { self.workspace },
            set: {
                self.host?.preferences.setValue($0, forKey: "workspace")
                self.settingsRevision += 1
            }
        )
    }

    var baseURLBinding: Binding<String> {
        Binding(
            get: { self.baseURL },
            set: {
                self.host?.preferences.setValue($0, forKey: "baseURL")
                self.settingsRevision += 1
            }
        )
    }

    var tokenBinding: Binding<String> {
        Binding(
            get: { self.tokenStore.read() ?? "" },
            set: {
                self.tokenStore.write($0)
                self.settingsRevision += 1
            }
        )
    }
    var isConfigured: Bool { !workspace.isEmpty && !(tokenStore.read() ?? "").isEmpty }
    func openSettings() { _ = host?.workspace.openSettings() }
}

extension PlaneTasksDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [ShelfWidgetDescriptor(id: "plane-tasks", title: "Plane Tasks", systemImage: "checklist", layoutTraits: ShelfWidgetLayoutTraits(preferredSoloWidth: 520, preferredPairedWidth: 260, contentHeight: .fixed(340)), searchKeywords: ["plane", "tasks", "assigned", "work items"])]
    }
    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView { AnyView(PlaneTasksWidget(droplet: self, context: context)) }
    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? { nil }
}

extension PlaneTasksDroplet: SettingsPaneProviding {
    public func makeSettingsPane(context: SettingsPaneContext) -> AnyView { AnyView(PlaneTasksSettings(droplet: self)) }
    public var settingsSearchEntries: [SettingsSearchEntry] { [SettingsSearchEntry(title: "Plane connection", keywords: ["plane", "token", "workspace", "API"])] }
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

    var body: some View {
        Group {
            if context.isCompact {
                compactContent
            } else {
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
        // Preserve the internal breathing room that was present in the earlier layout.
        .padding(.horizontal, DroppySpacing.md)
        .padding(.top, DroppySpacing.md)
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var compactContent: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(spacing: DroppySpacing.xsm) {
                Image(systemName: "checklist")
                    .font(.system(size: 10, weight: .medium))
                Text("Plane Tasks")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            Text("\(droplet.tasks.count)").font(.system(size: 26, weight: .semibold, design: .rounded))
            Text("assigned tasks").font(.caption).foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            Spacer(minLength: 0)
        }
    }

    private var taskListScreen: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(spacing: DroppySpacing.xsm) {
                Image(systemName: "checklist")
                    .font(.system(size: 10, weight: .medium))
                Text("Plane Tasks")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(droplet.visibleTasks.count)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .padding(.horizontal, DroppySpacing.xsm)
                    .padding(.vertical, 2)
                    .background(AdaptiveColors.notchSurfaceCardFill, in: Capsule(style: .continuous))
                Spacer(minLength: 0)
                Button { droplet.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(DroppyCircleButtonStyle(size: 20))
                .help("Refresh")
            }
            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            switch droplet.state {
                case .needsSetup:
                    Text("Please configure your Plane workspace and token in settings.").font(.caption).foregroundStyle(.secondary)
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding()
                case .loaded:
                    VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                        HStack(spacing: DroppySpacing.xsm) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                            TextField("Search title, ID, project…", text: $droplet.searchText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                            if !droplet.searchText.isEmpty {
                                Button {
                                    droplet.searchText = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 12))
                                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                                }
                                .buttonStyle(.plain)
                                .help("Clear search")
                            }
                        }
                        .padding(.horizontal, DroppySpacing.sm)
                        .padding(.vertical, DroppySpacing.xsm)
                        .background(
                            AdaptiveColors.notchSurfaceCardFill,
                            in: RoundedRectangle(cornerRadius: DroppyRadius.medium, style: .continuous)
                        )

                        HStack(alignment: .center, spacing: DroppySpacing.sm) {
                            statusChips
                                .frame(maxWidth: .infinity, alignment: .leading)
                            projectFilter
                        }
                    }
                    .onChange(of: droplet.searchText) { _, _ in
                        droplet.selectedTaskID = nil
                    }
                    GeometryReader { proxy in
                        ScrollView(.vertical) {
                            VStack(alignment: .leading, spacing: 6) {
                                ScrollViewScrollerHider()
                                    .frame(width: 0, height: 0)
                                ForEach(droplet.visibleTasks) { task in
                                    taskRow(task)
                                }
                                if droplet.visibleTasks.isEmpty { Text("No tasks match these filters.").font(.caption).foregroundStyle(.secondary).padding(.vertical, 8) }
                            }
                            .frame(width: proxy.size.width, alignment: .leading)
                        }
                        .scrollIndicators(.hidden, axes: .vertical)
                    }
                    .frame(maxHeight: 200)
                case .failed(let message):
                    Text(message).foregroundStyle(.red).font(.caption)
            }
            Spacer(minLength: 0)
        }
    }
    
    private var projectFilter: some View {
        Button {
            isProjectPopoverPresented.toggle()
        } label: {
            HStack(spacing: DroppySpacing.xsm) {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .medium))
                Text(droplet.selectedProject == "All" ? "Project" : droplet.selectedProject)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
        }
        .buttonStyle(DroppyQuietButtonStyle(size: .small))
        .fixedSize()
        .help("Filter by project")
        .popover(isPresented: $isProjectPopoverPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: DroppySpacing.xsm) {
                Text("Projects")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .padding(.horizontal, DroppySpacing.sm)
                    .padding(.top, DroppySpacing.xsm)

                projectOption("All projects", value: "All")
                Divider().overlay(AdaptiveColors.notchSurfaceTertiaryText.opacity(0.25))
                ForEach(droplet.projects.filter { $0 != "All" }, id: \.self) { project in
                    projectOption(project, value: project)
                }
            }
            .padding(DroppySpacing.sm)
            .frame(minWidth: 210, maxWidth: 280)
            .droppyFlatGlassControls()
            .presentationCompactAdaptation(.popover)
        }
    }

    private func projectOption(_ title: String, value: String) -> some View {
        Button {
            droplet.selectedProject = value
            droplet.selectedStatuses.removeAll()
            droplet.selectedTaskID = nil
            isProjectPopoverPresented = false
        } label: {
            HStack(spacing: DroppySpacing.sm) {
                Text(title)
                    .font(.system(size: 12, weight: droplet.selectedProject == value ? .semibold : .regular))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if droplet.selectedProject == value {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            .padding(.horizontal, DroppySpacing.sm)
            .padding(.vertical, DroppySpacing.xsm)
            .contentShape(RoundedRectangle(cornerRadius: DroppyRadius.medium, style: .continuous))
        }
        .buttonStyle(DroppyGlassButtonStyle())
    }

    private var canScrollChipsLeft: Bool { chipsOffsetX > 1 }
    private var canScrollChipsRight: Bool { (chipsContentWidth - chipsViewportWidth - chipsOffsetX) > 1 }

    private var statusChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DroppySpacing.xsm) {
                chip(label: "All", isSelected: droplet.selectedStatuses.isEmpty) {
                    withAnimation(.snappy(duration: 0.22)) {
                        droplet.selectedStatuses.removeAll()
                    }
                }
                ForEach(droplet.statusFilterOptions) { option in
                    let isOn = droplet.selectedStatuses.contains(option.id)
                    chip(label: option.label, isSelected: isOn, dotColor: groupColor(option.group)) {
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

    private func chip(label: String, isSelected: Bool, dotColor: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let dotColor {
                    Circle()
                        .fill(dotColor)
                        .overlay(Circle().stroke(isSelected ? Color.black.opacity(0.9) : AdaptiveColors.notchSurfaceCardFill, lineWidth: 1.25))
                        .frame(width: 7, height: 7)
                        .shadow(color: isSelected ? AdaptiveColors.notchSurfaceCardFill.opacity(0.9) : .clear, radius: 1)
                }
                Text(label)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
            }
                .padding(.horizontal, DroppySpacing.sm)
                .padding(.vertical, DroppySpacing.xsm)
                .foregroundStyle(isSelected ? Color.white : AdaptiveColors.notchSurfaceSecondaryText)
                .background {
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(Color.blue)
                    } else {
                        Capsule(style: .continuous)
                            .fill(AdaptiveColors.notchSurfaceCardFill)
                    }
                }
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.22), value: isSelected)
        .help(isSelected ? "Selected" : "Filter by \(label)")
    }
    
    private func taskRow(_ task: PlaneTask) -> some View {
        Button {
            showDetails(for: task)
        } label: {
            HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(task.reference.uppercased())
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                        .lineLimit(1)
                    if let date = formattedTargetDate(task.targetDate) {
                        Circle().fill(AdaptiveColors.notchSurfaceTertiaryText.opacity(0.65)).frame(width: 3, height: 3)
                        HStack(spacing: 4) {
                            Image(systemName: "calendar").font(.system(size: 9, weight: .regular))
                            Text(date).font(.system(size: 10, weight: .regular))
                        }
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                Text(task.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    priorityChip(task.priority)
                    stateChip(task)
                    projectChip(task.project)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AdaptiveColors.notchSurfaceCardFill, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("Show task details")
    }

    private func showCopiedFeedback(_ key: String) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.68)) { copiedFeedback = key }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(.easeOut(duration: 0.2)) {
                if copiedFeedback == key { copiedFeedback = nil }
            }
        }
    }

    private func formattedTargetDate(_ rawDate: String?) -> String? {
        guard let rawDate, !rawDate.isEmpty else { return nil }
        let input = ISO8601DateFormatter()
        input.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = input.date(from: rawDate)
            ?? ISO8601DateFormatter().date(from: rawDate)
            ?? dateOnlyFormatter.date(from: String(rawDate.prefix(10)))
        guard let date else { return rawDate }
        return targetDateFormatter.string(from: date)
    }

    private var dateOnlyFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    private var targetDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }

    private func priorityChip(_ priority: String) -> some View {
        let normalized = priority.lowercased()
        let label: String = {
            switch normalized {
            case "urgent": return "Urgent"
            case "high": return "High"
            case "medium": return "Medium"
            case "low": return "Low"
            default: return "No priority"
            }
        }()
        let tint: Color = {
            switch normalized {
            case "urgent": return .purple
            case "high": return .red
            case "medium": return .orange
            case "low": return .green
            default: return AdaptiveColors.notchSurfaceTertiaryText
            }
        }()
        let filledBars: Int = {
            switch normalized {
            case "low": return 1
            case "medium": return 2
            case "high", "urgent": return 3
            default: return 0
            }
        }()

        return HStack(spacing: 5) {
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(index < filledBars ? tint : tint.opacity(0.22))
                        .frame(width: 3, height: CGFloat(4 + index * 2))
                }
            }
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(tint.opacity(0.13), in: Capsule(style: .continuous))
        .help("Priority: \(label)")
    }

    private func stateChip(_ task: PlaneTask) -> some View {
        let tint = groupColor(task.stateGroup)
        return HStack(spacing: 4) {
            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
            Text(task.status)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(tint.opacity(0.13), in: Capsule(style: .continuous))
        .help("State: \(task.status)")
    }

    private func projectChip(_ project: String) -> some View {
        Text(project)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(AdaptiveColors.notchSurfaceCardFill.opacity(0.9), in: Capsule(style: .continuous))
            .help("Project: \(project)")
    }

    private func detailScreen(_ task: PlaneTask) -> some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(spacing: DroppySpacing.xsm) {
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
                Spacer(minLength: 0)
                detailActionGroup(task)
            }
            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)

            detailView(task)
            Spacer(minLength: 0)
        }
    }

    private func detailView(_ task: PlaneTask) -> some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(spacing: 6) {
                Text(task.reference.uppercased())
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                if let date = formattedTargetDate(task.targetDate) {
                    Image(systemName: "calendar")
                        .font(.system(size: 8))
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    Text(date)
                        .font(.system(size: 9))
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                priorityChip(task.priority)
                stateChip(task)
                projectChip(task.project)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(task.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if task.descriptionText.isEmpty {
                Text("No description available.")
                    .font(.system(size: 10))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        ScrollViewScrollerHider()
                            .frame(width: 0, height: 0)
                        Text(task.descriptionText)
                            .font(.system(size: 11))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 2)
                            .padding(.vertical, 2)
                    }
                }
                .scrollIndicators(.hidden, axes: .vertical)
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailActionGroup(_ task: PlaneTask) -> some View {
        HStack(spacing: 2) {
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
        }
        .padding(2)
        .background(AdaptiveColors.notchSurfaceCardFill, in: Capsule(style: .continuous))
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
                .font(.system(size: 9, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(isCopied ? Color.green : AdaptiveColors.notchSurfaceSecondaryText)
                .frame(width: 23, height: 23)
        }
        .buttonStyle(.plain)
        .help(help)
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
                        infoTip: "Fill in the details above, then refresh to load your assigned tasks."
                    ) {
                        statusChip(isReady: droplet.isConfigured)
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

    /// A small status chip, colored green when ready and orange when it
    /// still needs setup. DropletValuePill has no color parameter, so this
    /// is a lightweight custom chip using the same rounded, borderless
    /// language as the rest of the design system.
    private func statusChip(isReady: Bool) -> some View {
        let color: Color = isReady ? .green : .orange
        return Text(isReady ? "Ready" : "Needs setup")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, DroppySpacing.sm)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule(style: .continuous))
    }
}

fileprivate enum LoadState: Equatable { case needsSetup, loading, loaded, failed(String) }
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
    let state: PlaneState?
    let stateID: String?
    let assigneeIDs: [String]

    enum CodingKeys: String, CodingKey {
        case id, name, priority, state, assignees, description
        case descriptionHTML = "description_html"
        case sequenceID = "sequence_id"
        case targetDate = "target_date"
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
    let id: String; let name: String; let reference: String; let targetDate: String?
    let priority: String; let status: String; let stateGroup: String; let descriptionText: String
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
                .replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\\n", options: .regularExpression)
                .replacingOccurrences(of: "(?i)</p>|</div>|</li>", with: "\\n", options: .regularExpression)
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return PlaneTask(id: item.id, name: item.name, reference: reference, targetDate: item.targetDate,
                             priority: item.priority ?? "none", status: resolvedStatus ?? "Unknown",
                             stateGroup: resolvedGroup, descriptionText: plainDescription,
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
