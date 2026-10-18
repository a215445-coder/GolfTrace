import AVFoundation
import GoogleSignIn
import SwiftUI

@main
struct GolfTraceApp: App {
    @StateObject private var session = AppSession()

    var body: some Scene {
        WindowGroup {
            Group {
                if session.route == .login {
                    LoginView()
                } else {
                    HomeView()
                }
            }
            .environmentObject(session)
            .onOpenURL { url in
                // Google 授权完成后通过回调 URL Scheme 跳回 App
                GIDSignIn.sharedInstance.handle(url)
            }
        }
    }
}

@MainActor
final class AppSession: ObservableObject {
    @Published var route: Route = .login
    @Published var currentShot: ShotRecord?
    @Published var errorMessage: String?
    @Published var library: [ShotRecord] = []
    /// Google 登录认证后的用户信息（来自 Google 官方 SDK）
    @Published var googleUser: GoogleUserProfile?

    private let store = ShotLibrary()

    enum Route: Equatable {
        case login
        case home
        case review
    }

    init() {
        library = store.loadIndex()
    }

    /// 登录完成（Apple 登录成功或跳过登录）后进入主界面
    func completeLogin() {
        route = .home
    }

    func importVideo(from sourceURL: URL) {
        Task {
            do {
                let stored = try store.importVideo(from: sourceURL)
                var shot = stored
                // 回填视频像素尺寸：舞台按此比例布局，轨迹点坐标才能与画面严格对应
                if shot.trace.videoWidth <= 0 || shot.trace.videoHeight <= 0 {
                    let asset = AVURLAsset(url: shot.videoURL)
                    if let track = try? await asset.loadTracks(withMediaType: .video).first {
                        let size = VideoGeometry.displaySize(for: track)
                        shot.trace.videoWidth = size.width
                        shot.trace.videoHeight = size.height
                    }
                }
                try store.save(shot)
                currentShot = shot
                library = store.loadIndex()
                route = .review
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func importImage(from sourceURL: URL) {
        Task {
            do {
                let stored = try store.importImage(from: sourceURL)
                try store.save(stored)
                currentShot = stored
                library = store.loadIndex()
                route = .review
            } catch {
                errorMessage = error.localizedDescription
            }
        }
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
