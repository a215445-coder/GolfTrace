import SwiftUI

@main
struct GolfTraceApp: App {
    @StateObject private var session = AppSession()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(session)
        }
    }
}

@MainActor
final class AppSession: ObservableObject {
    @Published var route: Route = .home
    @Published var currentShot: ShotRecord?
    @Published var isProcessing = false
    @Published var processingMessage = "正在识别轨迹…"
    @Published var errorMessage: String?
    @Published var library: [ShotRecord] = []

    private let store = ShotLibrary()

    enum Route: Equatable {
        case home
        case review
    }

    init() {
        library = store.loadIndex()
    }

    func ingestVideo(from sourceURL: URL) {
        Task { await process(sourceURL: sourceURL) }
    }

    func process(sourceURL: URL) async {
        isProcessing = true
        processingMessage = "正在导入视频…"
        errorMessage = nil
        do {
            let stored = try store.importVideo(from: sourceURL)
            processingMessage = "正在识别球的轨迹…"
            let videoURL = stored.videoURL
            let result = try await Task.detached(priority: .userInitiated) {
                try await TrajectoryDetector().detect(in: videoURL)
            }.value
            var shot = stored
            shot.trace = result
            try store.save(shot)
            currentShot = shot
            library = store.loadIndex()
            route = .review
        } catch {
            errorMessage = error.localizedDescription
        }
        isProcessing = false
    }

    func saveCurrentShot() {
        guard let currentShot else { return }
        try? store.save(currentShot)
        library = store.loadIndex()
    }

    func open(_ shot: ShotRecord) {
        currentShot = store.loadShot(id: shot.id) ?? shot
        route = .review
    }

    func goHome() {
        currentShot = nil
        route = .home
        errorMessage = nil
    }

    func delete(_ shot: ShotRecord) {
        store.delete(shot)
        library = store.loadIndex()
        if currentShot?.id == shot.id {
            goHome()
        }
    }
}
