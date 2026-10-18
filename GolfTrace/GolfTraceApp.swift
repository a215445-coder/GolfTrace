import AVFoundation
import SwiftUI

@main
struct GolfTraceApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = AppSession()

    var body: some Scene {
        WindowGroup {
            ZStack {
                if session.route == .login {
                    LoginView()
                        .transition(.asymmetric(insertion: .identity, removal: .loginZoomOut))
                } else {
                    HomeView()
                        .transition(.homeZoomIn)
                }
            }
            .environmentObject(session)
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: session.route)
        }
    }
}

@MainActor
final class AppSession: ObservableObject {
    @Published var route: Route = .login
    @Published var currentShot: ShotRecord?
    @Published var errorMessage: String?
    @Published var library: [ShotRecord] = []

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

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        NSLog("[GolfTraceAppDelegate] didFinishLaunching，delegate 已生效")
        return true
    }
}

// MARK: - 登录 → 主界面过渡（纯变换动画，无离屏遮罩，高刷屏不丢帧）

private struct ScreenTransitionModifier: ViewModifier, Animatable {
    var scale: CGFloat
    var opacity: Double
    var offsetY: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, Double>, CGFloat> {
        get { AnimatablePair(AnimatablePair(scale, opacity), offsetY) }
        set {
            scale = newValue.first.first
            opacity = newValue.first.second
            offsetY = newValue.second
        }
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .opacity(opacity)
            .offset(y: offsetY)
    }
}

extension AnyTransition {
    /// 登录页退出：轻微放大 + 淡出（像镜头穿过屏幕进入 App）
    static var loginZoomOut: AnyTransition {
        .modifier(
            active: ScreenTransitionModifier(scale: 1.08, opacity: 0, offsetY: 0),
            identity: ScreenTransitionModifier(scale: 1, opacity: 1, offsetY: 0)
        )
    }

    /// 主界面进入：从小尺寸淡入，弹性回弹到原位
    static var homeZoomIn: AnyTransition {
        .modifier(
            active: ScreenTransitionModifier(scale: 0.9, opacity: 0, offsetY: 28),
            identity: ScreenTransitionModifier(scale: 1, opacity: 1, offsetY: 0)
        )
    }
}
