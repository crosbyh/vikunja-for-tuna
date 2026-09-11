import Foundation
import TunaKit

/// Live-search root: type to search open tasks server-side, or browse them grouped by due date.
public final class VikunjaTasksCatalog: Catalog, StartupScanningCatalog {
  public let identifier: String
  public let name: String
  public let scansOnStartup = false

  private let newTaskItem = VikunjaNewTaskItem()
  private var changeObserver: NSObjectProtocol?

  private lazy var rootItem = ScopedSearchBrowseCatalogItem(
    title: "Vikunja",
    id: VikunjaExtension.tasksCatalogIdentifier,
    detail: "Search open tasks, or browse them by due date",
    catalogIcon: .init(symbolName: "checkmark.circle", color: .green),
    configuration: ScopedSearchConfiguration(debounce: .milliseconds(300), searchOnChange: true),
    loadingItemProvider: { VikunjaCatalogSupport.loadingItem("Vikunja tasks") },
    errorItemProvider: { VikunjaCatalogSupport.errorItem($0) },
    didLoad: { [identifier] in VikunjaCatalogSupport.postScanFinished(identifier: identifier) },
    loadChildren: { try await Self.loadBrowseChildren() },
    searchHandler: { query in try await Self.search(query: query) }
  )

  public var objects: [CatalogItem] {
    [rootItem, newTaskItem]
  }

  public required init(definition: CatalogDefinition) {
    self.identifier = definition.identifier
    self.name = definition.name
    changeObserver = NotificationCenter.default.addObserver(
      forName: VikunjaDataDidChange, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.rootItem.reset()
        VikunjaCatalogSupport.postScanFinished(identifier: self.identifier)
      }
    }
  }

  deinit {
    if let changeObserver {
      NotificationCenter.default.removeObserver(changeObserver)
    }
  }

  public func scan() async {
    rootItem.reset()
    VikunjaCatalogSupport.postScanFinished(identifier: identifier)
  }

  // MARK: Browse

  private nonisolated static func loadBrowseChildren() async throws -> [CatalogItem] {
    let connections = VikunjaCatalogSupport.connections()
    guard !connections.isEmpty else {
      return [VikunjaCatalogSupport.authRequiredItem()]
    }

    let results = try await VikunjaCatalogSupport.loadPerConnection(connections) { connection in
      try await Self.loadTasks(for: connection)
    }
    let totalConnections = connections.count

    if totalConnections == 1, let first = results.first {
      return makeBuckets(
        first.payload,
        connection: first.connection,
        totalConnections: 1,
        baseIdentifier: "vikunja.tasks"
      )
    }

    return results.map { result in
      VikunjaSectionItem(
        title: result.connection.displayName,
        id: "vikunja.tasks.connection.\(result.offset)",
        detail: "Open tasks",
        symbolName: "checkmark.circle",
        iconColor: .green,
        children: makeBuckets(
          result.payload,
          connection: result.connection,
          totalConnections: totalConnections,
          baseIdentifier: "vikunja.tasks.\(result.offset)"
        ),
        sortOrder: result.offset
      )
    }
  }

  private struct ConnectionTasks: Sendable {
    let tasks: [VikunjaTask]
    let projects: [VikunjaProject]
    let server: VikunjaServerConfiguration
  }

  private nonisolated static func loadTasks(for connection: VikunjaConnection) async throws
    -> ConnectionTasks
  {
    let client = try VikunjaAPIClient(connection: connection)
    async let tasks = client.fetchOpenTasks()
    async let projects = VikunjaProjectCache.shared.projects(for: connection, client: client)
    return ConnectionTasks(tasks: try await tasks, projects: try await projects, server: client.server)
  }

  private nonisolated static func makeBuckets(
    _ payload: ConnectionTasks,
    connection: VikunjaConnection,
    totalConnections: Int,
    baseIdentifier: String
  ) -> [CatalogItem] {
    let now = Date()
    let sorted = VikunjaCatalogSupport.sortedByDue(payload.tasks)
    var grouped: [VikunjaCatalogSupport.DueBucket: [VikunjaTask]] = [:]
    for task in sorted {
      grouped[VikunjaCatalogSupport.dueBucket(for: task, now: now), default: []].append(task)
    }

    let sections: [CatalogItem] = VikunjaCatalogSupport.DueBucket.allCases.compactMap { bucket in
      guard let tasks = grouped[bucket], !tasks.isEmpty else { return nil }
      return VikunjaSectionItem(
        title: bucket.title,
        id: "\(baseIdentifier).\(bucket)",
        detail: tasks.count == 1 ? "1 task" : "\(tasks.count) tasks",
        symbolName: bucket.symbolName,
        iconColor: bucket.iconColor,
        children: tasks.map {
          makeItem($0, payload: payload, connection: connection, totalConnections: totalConnections)
        },
        sortOrder: bucket.rawValue
      )
    }

    let (_, projectRoots) = VikunjaProjectsCatalog.makeProjectItems(
      payload.projects,
      connection: connection,
      server: payload.server,
      catalogIdentifier: VikunjaExtension.tasksCatalogIdentifier
    )
    let byProject: [CatalogItem] =
      projectRoots.isEmpty
      ? []
      : [
        VikunjaSectionItem(
          title: "By Project",
          id: "\(baseIdentifier).by-project",
          detail: projectRoots.count == 1 ? "1 project" : "\(projectRoots.count) projects",
          symbolName: "folder",
          iconColor: .blue,
          children: projectRoots,
          sortOrder: VikunjaCatalogSupport.DueBucket.allCases.count
        )
      ]

    guard !sections.isEmpty else {
      return [
        VikunjaCatalogSupport.emptyItem(
          title: "No open tasks", message: "Everything in Vikunja is done.")
      ] + byProject
    }
    return sections + byProject
  }

  private nonisolated static func makeItem(
    _ task: VikunjaTask,
    payload: ConnectionTasks,
    connection: VikunjaConnection,
    totalConnections: Int
  ) -> VikunjaTaskItem {
    VikunjaCatalogSupport.makeTaskItem(
      task,
      projectTitle: payload.projects.first { $0.id == task.projectID }?.title,
      connection: connection,
      totalConnections: totalConnections,
      server: payload.server
    )
  }

  // MARK: Search

  private nonisolated static func search(query: String) async throws -> [CatalogItem] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let connections = VikunjaCatalogSupport.connections()
    guard !connections.isEmpty else {
      return [VikunjaCatalogSupport.authRequiredItem()]
    }

    let totalConnections = connections.count
    let results = try await VikunjaCatalogSupport.loadPerConnection(connections) { connection in
      let client = try VikunjaAPIClient(connection: connection)
      async let tasks = trimmed.isEmpty
        ? client.fetchOpenTasks() : client.searchOpenTasks(query: trimmed)
      async let projects = VikunjaProjectCache.shared.projects(for: connection, client: client)
      return ConnectionTasks(
        tasks: try await tasks, projects: try await projects, server: client.server)
    }

    let items = results.flatMap { result in
      VikunjaCatalogSupport.sortedByDue(result.payload.tasks).map {
        makeItem(
          $0, payload: result.payload, connection: result.connection,
          totalConnections: totalConnections)
      }
    }

    guard !items.isEmpty else {
      return [
        VikunjaCatalogSupport.emptyItem(
          title: trimmed.isEmpty ? "No open tasks" : "No matching tasks",
          message: trimmed.isEmpty
            ? "Everything in Vikunja is done."
            : "No open task matches “\(trimmed)”.")
      ]
    }
    return items
  }
}

/// Short-lived per-connection project list so task details can show project titles without a
/// projects request on every keystroke.
actor VikunjaProjectCache {
  static let shared = VikunjaProjectCache()

  private struct Entry {
    let projects: [VikunjaProject]
    let fetchedAt: Date
  }

  private var entries: [String: Entry] = [:]
  private let ttl: TimeInterval = 60

  func projects(for connection: VikunjaConnection, client: VikunjaAPIClient) async throws
    -> [VikunjaProject]
  {
    if let entry = entries[connection.id], Date().timeIntervalSince(entry.fetchedAt) < ttl {
      return entry.projects
    }
    let projects = try await client.fetchProjects()
    entries[connection.id] = Entry(projects: projects, fetchedAt: Date())
    return projects
  }

  func invalidate() {
    entries = [:]
  }
}
