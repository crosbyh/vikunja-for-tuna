import Foundation
import TunaKit
import XCTest

@testable import TunaVikunja

@MainActor
final class VikunjaExtensionTests: XCTestCase {
  // MARK: Declaration

  func testDeclarationDeclaresStableIdentifiers() throws {
    let bundle = Bundle(for: VikunjaExtension.self)
    let ext = try VikunjaExtension(bundle: bundle)
    let declaration = try XCTUnwrap(ext.declaration)

    XCTAssertEqual(declaration.catalogs.map(\.id), ["vikunja", "vikunja.projects"])
    XCTAssertEqual(declaration.actionCatalogs.map(\.id), ["vikunja.actions"])
    XCTAssertEqual(declaration.catalogs[0].presentation, .liveSearch)
    XCTAssertEqual(declaration.catalogs[1].presentation, .source)
    XCTAssertEqual(declaration.compatibility?.minTuna, "0.96")
    XCTAssertEqual(declaration.compatibility?.minTunaKit, "1.22.0")
    XCTAssertEqual(declaration.settings.map(\.key), ["DefaultProject"])
    XCTAssertEqual(
      Set(declaration.typeRegistrations.map(\.typeID)), [.vikunjaTask, .vikunjaProject])
    XCTAssertTrue(declaration.typeRegistrations.allSatisfy { $0.inheritsFrom == [.url] })
    XCTAssertEqual(ext.connectionDefinitions.map(\.providerIdentifier), ["vikunja"])
    XCTAssertTrue(ext.connectionDefinitions[0].supportsBaseURL)
    XCTAssertEqual(ext.connectionDefinitions[0].kind, .secret)
  }

  // MARK: Server configuration

  func testServerConfigurationNormalizesBareHost() throws {
    let server = try VikunjaServerConfiguration(baseURLString: "tasks.example.com/")
    XCTAssertEqual(server.webBaseURL.absoluteString, "https://tasks.example.com")
    XCTAssertEqual(server.apiBaseURL.absoluteString, "https://tasks.example.com/api/v1")
    XCTAssertEqual(server.taskURL(id: 42).absoluteString, "https://tasks.example.com/tasks/42")
    XCTAssertEqual(server.projectURL(id: 3).absoluteString, "https://tasks.example.com/projects/3")
  }

  func testServerConfigurationStripsAPIPathAndSubpaths() throws {
    let server = try VikunjaServerConfiguration(baseURLString: "https://host.tld/vikunja/api/v1/")
    XCTAssertEqual(server.webBaseURL.absoluteString, "https://host.tld/vikunja")
    XCTAssertEqual(server.apiBaseURL.absoluteString, "https://host.tld/vikunja/api/v1")
  }

  func testServerConfigurationRejectsMissingOrInvalidURLs() {
    XCTAssertThrowsError(try VikunjaServerConfiguration(baseURLString: "   ")) { error in
      XCTAssertEqual(error as? VikunjaAPIError, .missingServerURL)
    }
    XCTAssertThrowsError(try VikunjaServerConfiguration(baseURLString: "ftp://host")) { error in
      XCTAssertEqual(error as? VikunjaAPIError, .invalidServerURL)
    }
  }

  // MARK: Parsing

  func testParseTaskHandlesNullDatesLabelsAndPriority() throws {
    let json = """
      {"id": 97, "title": "Set up Darktable", "done": false, "due_date": "2026-07-31T09:00:00-07:00",
       "priority": 3, "project_id": 2, "identifier": "#1", "description": "",
       "labels": [{"id": 1, "title": "@home", "hex_color": "ffbe0b"}],
       "done_at": "0001-01-01T00:00:00Z", "updated": "2026-08-18T06:34:44-07:00"}
      """
    let payload = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    let task = try XCTUnwrap(VikunjaAPIClient.parseTask(payload))

    XCTAssertEqual(task.id, 97)
    XCTAssertEqual(task.priorityName, "High")
    XCTAssertEqual(task.labels.map(\.title), ["@home"])
    XCTAssertNotNil(task.dueDate)
    XCTAssertNotNil(task.updatedAt)
    XCTAssertNil(VikunjaAPIClient.parseDate("0001-01-01T00:00:00Z"))
    XCTAssertNil(VikunjaAPIClient.parseDate(nil))
  }

  func testParseProjectSkipsNothingButFetchFiltersArchivedAndPseudoProjects() throws {
    let payload: [String: Any] = [
      "id": -1, "title": "Favorites", "is_archived": false, "parent_project_id": 0,
    ]
    let project = try XCTUnwrap(VikunjaAPIClient.parseProject(payload))
    XCTAssertEqual(project.id, -1)
    XCTAssertEqual(project.hexColor, "")
  }

  func testErrorMapping() {
    XCTAssertEqual(VikunjaAPIClient.mapError(status: 401, data: Data()), .invalidToken)
    XCTAssertEqual(VikunjaAPIClient.mapError(status: 403, data: Data()), .missingScope)
    XCTAssertEqual(VikunjaAPIClient.mapError(status: 404, data: Data()), .notFound)
    XCTAssertEqual(
      VikunjaAPIClient.mapError(status: 500, data: Data(#"{"message":"boom"}"#.utf8)),
      .unexpectedStatus(500, "boom"))
  }

  // MARK: Grouping and formatting

  func testDueBucketsAndSorting() {
    let now = Date()
    let calendar = Calendar.autoupdatingCurrent
    let overdue = makeTask(id: 1, title: "b", due: calendar.date(byAdding: .day, value: -3, to: now))
    let today = makeTask(id: 2, title: "a", due: now)
    let soon = makeTask(id: 3, title: "c", due: calendar.date(byAdding: .day, value: 3, to: now))
    let later = makeTask(id: 4, title: "d", due: calendar.date(byAdding: .day, value: 30, to: now))
    let undatedLow = makeTask(id: 5, title: "z", due: nil, priority: 1)
    let undatedHigh = makeTask(id: 6, title: "y", due: nil, priority: 4)

    XCTAssertEqual(VikunjaCatalogSupport.dueBucket(for: overdue, now: now), .overdue)
    XCTAssertEqual(VikunjaCatalogSupport.dueBucket(for: today, now: now), .today)
    XCTAssertEqual(VikunjaCatalogSupport.dueBucket(for: soon, now: now), .upcoming)
    XCTAssertEqual(VikunjaCatalogSupport.dueBucket(for: later, now: now), .later)
    XCTAssertEqual(VikunjaCatalogSupport.dueBucket(for: undatedLow, now: now), .undated)

    let sorted = VikunjaCatalogSupport.sortedByDue(
      [undatedLow, later, undatedHigh, soon, today, overdue])
    XCTAssertEqual(sorted.map(\.id), [1, 2, 3, 4, 6, 5])
  }

  func testTaskDetailMentionsProjectDueAndLabels() {
    let task = makeTask(id: 1, title: "t", due: Date(), priority: 5, labels: ["@home", "@agent"])
    let detail = VikunjaCatalogSupport.taskDetail(
      task, projectTitle: "Inbox", connection: nil, totalConnections: 1)
    XCTAssertEqual(detail, "Inbox · Due today · Do now · @home @agent")
  }

  func testResolveDefaultProjectPrefersIDThenTitleThenInbox() {
    let projects = [
      VikunjaProject(
        id: 1, title: "Inbox", description: "", parentProjectID: 0, hexColor: "",
        isArchived: false, isFavorite: false),
      VikunjaProject(
        id: 7, title: "Work", description: "", parentProjectID: 0, hexColor: "",
        isArchived: false, isFavorite: false),
    ]
    XCTAssertEqual(
      VikunjaCatalogSupport.resolveDefaultProject(projects, preference: "#7")?.id, 7)
    XCTAssertEqual(
      VikunjaCatalogSupport.resolveDefaultProject(projects, preference: "work")?.id, 7)
    XCTAssertEqual(
      VikunjaCatalogSupport.resolveDefaultProject(projects, preference: "nope")?.id, 1)
    XCTAssertNil(VikunjaCatalogSupport.resolveDefaultProject([], preference: "Inbox"))
  }

  func testProjectPathFollowsParents() {
    let home = VikunjaProject(
      id: 2, title: "Home", description: "", parentProjectID: 0, hexColor: "",
      isArchived: false, isFavorite: false)
    let ha = VikunjaProject(
      id: 3, title: "Home assistant", description: "", parentProjectID: 2, hexColor: "01c7fc",
      isArchived: false, isFavorite: false)
    XCTAssertEqual(VikunjaCatalogSupport.projectPath(ha, in: [home, ha]), "Home › Home assistant")
    XCTAssertEqual(VikunjaCatalogSupport.projectPath(home, in: [home, ha]), "Home")
  }

  func testIconColorMapping() {
    XCTAssertEqual(VikunjaCatalogSupport.iconColor(forHex: "01c7fc"), .teal)
    XCTAssertEqual(VikunjaCatalogSupport.iconColor(forHex: "#2ecc71"), .green)
    XCTAssertEqual(VikunjaCatalogSupport.iconColor(forHex: "ff0000"), .red)
    XCTAssertEqual(VikunjaCatalogSupport.iconColor(forHex: ""), .blue)
    XCTAssertEqual(VikunjaCatalogSupport.iconColor(forHex: "808080"), .gray)
  }

  // MARK: Catalog shapes

  func testProjectItemsNestChildrenUnderParents() throws {
    let record = ExtensionConnectionRecord(
      providerIdentifier: "vikunja", displayName: "Test", baseURLString: "https://v.example")
    let connection = VikunjaConnection(record: record, accessToken: "token")
    let projects = [
      VikunjaProject(
        id: 2, title: "Home", description: "", parentProjectID: 0, hexColor: "",
        isArchived: false, isFavorite: false),
      VikunjaProject(
        id: 3, title: "Home assistant", description: "", parentProjectID: 2, hexColor: "",
        isArchived: false, isFavorite: false),
      VikunjaProject(
        id: 1, title: "Inbox", description: "", parentProjectID: 0, hexColor: "",
        isArchived: false, isFavorite: false),
    ]
    let (all, roots) = VikunjaProjectsCatalog.makeProjectItems(
      projects,
      connection: connection,
      server: try VikunjaServerConfiguration(baseURLString: "https://v.example"),
      catalogIdentifier: "vikunja.projects"
    )

    XCTAssertEqual(all.count, 3)
    XCTAssertEqual(roots.map(\.title), ["Home", "Inbox"])
    XCTAssertEqual(all.map(\.id), [
      "vikunja.project.\(record.id).2",
      "vikunja.project.\(record.id).3",
      "vikunja.project.\(record.id).1",
    ])
    XCTAssertTrue(all.allSatisfy { $0.typeID == .vikunjaProject })
    XCTAssertEqual(all[0].path, "https://v.example/projects/2")
  }

  func testTasksCatalogExposesRootAndNewTaskEntry() {
    let catalog = VikunjaTasksCatalog(
      definition: CatalogDefinition(
        identifier: "vikunja", name: "Vikunja", enabledByDefault: true,
        presentation: .liveSearch, settings: []))
    XCTAssertFalse(catalog.scansOnStartup)
    XCTAssertEqual(catalog.objects.map(\.id), ["vikunja", "vikunja.new"])
    XCTAssertEqual(catalog.objects[1].typeID, .searchCatalogEntry)
  }

  // MARK: Actions

  func testActionGrammar() throws {
    let catalog = VikunjaActionsCatalog(
      definition: ActionCatalogDefinition(identifier: "vikunja.actions", name: "Vikunja"))
    XCTAssertEqual(
      catalog.actions.map(\.id), ["mark-done", "add-task", "add-task-to-project", "to"])

    let addToProject = try XCTUnwrap(catalog.actions.first { $0.id == "add-task-to-project" })
    XCTAssertNotNil(addToProject.batchCallback)
    XCTAssertEqual(addToProject.supportedSubjectTypes, [.textSnippet])
    XCTAssertEqual(addToProject.allowedTargetTypes, [.vikunjaProject])
    XCTAssertEqual(
      addToProject.targetSearchScope, .catalogs(["vikunja.projects"], preparation: .refresh))
    if case .required = addToProject.targetRequirement {} else {
      XCTFail("Add to Vikunja Project must require a target")
    }

    let markDone = try XCTUnwrap(catalog.actions.first { $0.id == "mark-done" } as? PredicateAwareAction)
    XCTAssertEqual(markDone.supportedSubjectTypes, [.vikunjaTask])
    let openTask = makeTaskItem(makeTask(id: 1, title: "open", due: nil))
    let doneTask = makeTaskItem(makeTask(id: 2, title: "done", due: nil, done: true))
    XCTAssertTrue(markDone.subjectPredicate?(openTask) ?? false)
    XCTAssertFalse(markDone.subjectPredicate?(doneTask) ?? true)

    let toAction = try XCTUnwrap(catalog.actions.first { $0.id == "to" } as? PredicateAwareAction)
    XCTAssertTrue(toAction.subjectPredicate?(VikunjaNewTaskItem()) ?? false)
    XCTAssertFalse(toAction.subjectPredicate?(openTask) ?? true)
    XCTAssertTrue(toAction.targetPredicate?(TextSnippetItem(text: "Buy milk")) ?? false)
    XCTAssertFalse(toAction.targetPredicate?(TextSnippetItem(text: "   ")) ?? true)

    let newTask = VikunjaNewTaskItem()
    XCTAssertTrue(newTask.allowsAction(toAction, catalogIdentifier: "vikunja.actions"))
    XCTAssertFalse(newTask.allowsAction(markDone, catalogIdentifier: "vikunja.actions"))
  }

  func testTaskItemIdentityTypeAndSearchKeys() {
    let item = makeTaskItem(makeTask(id: 12, title: "Buy milk", due: nil, labels: ["@errands"]))
    XCTAssertEqual(item.id, "vikunja.task.conn.12")
    XCTAssertEqual(item.typeID, .vikunjaTask)
    XCTAssertEqual(item.path, "https://v.example/tasks/12")
    XCTAssertEqual(item.textValue, "https://v.example/tasks/12")
    XCTAssertEqual(item.searchKeys, ["Buy milk", "Inbox", "@errands", "#12"])
  }

  // MARK: Helpers

  private func makeTask(
    id: Int, title: String, due: Date?, priority: Int = 0, labels: [String] = [],
    done: Bool = false
  ) -> VikunjaTask {
    VikunjaTask(
      id: id, title: title, description: "", done: done, dueDate: due, priority: priority,
      projectID: 1, identifier: "#\(id)",
      labels: labels.enumerated().map { VikunjaLabel(id: $0.offset, title: $0.element, hexColor: "") },
      updatedAt: nil)
  }

  private func makeTaskItem(_ task: VikunjaTask) -> VikunjaTaskItem {
    VikunjaTaskItem(
      task: task, connectionID: "conn", projectTitle: "Inbox",
      url: URL(string: "https://v.example/tasks/\(task.id)")!,
      detail: "Inbox")
  }
}
