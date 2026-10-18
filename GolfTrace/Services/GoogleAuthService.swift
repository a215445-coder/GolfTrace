import Foundation
import GoogleSignIn
import UIKit

/// Google 登录认证后的用户信息（来自 Google 官方 SDK，非前端伪造）
struct GoogleUserProfile {
    let userID: String
    let name: String
    let email: String
    let photoURL: URL?
}

enum GoogleAuthError: LocalizedError {
    /// 未配置：缺少 GoogleService-Info.plist 或 GoogleClientID
    case notConfigured
    case noPresenter
    case missingUser
    case canceled
    case network

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Google 登录尚未配置。\n\n请先在 Firebase 或 Google Cloud 控制台创建项目，为 iOS 应用（Bundle ID：app.golftrace.GolfTrace）创建 OAuth 客户端，然后将 GoogleService-Info.plist 放入工程（或提供客户端 ID）。"
        case .noPresenter:
            return "无法打开登录界面，请重试。"
        case .missingUser:
            return "Google 登录未返回用户信息，请重试。"
        case .canceled:
            return "已取消 Google 登录"
        case .network:
            return "网络错误，请检查网络后重试"
        }
    }
}

/// Google 登录服务：基于 GoogleSignIn-iOS 官方 SDK 的真实 OAuth 流程。
/// - 配置来源：优先读取工程中的 GoogleService-Info.plist（Firebase 配置），
///   否则读取 Info.plist 的 GoogleClientID；
/// - 不保存任何密钥；用户身份由 Google 返回的 ID Token 与用户信息构成，
///   后端如需鉴权，应校验 ID Token（前端不做真实性认定）。
final class GoogleAuthService {
    static let shared = GoogleAuthService()

    private init() {
        if let configuration = Self.loadConfiguration() {
            GIDSignIn.sharedInstance.configuration = configuration
        }
    }

    /// 是否已完成客户端配置
    var isConfigured: Bool {
        GIDSignIn.sharedInstance.configuration != nil
    }

    /// 发起 Google 登录（会弹出 Google 授权页/Google App）
    func signIn(completion: @escaping (Result<GoogleUserProfile, Error>) -> Void) {
        guard let configuration = GIDSignIn.sharedInstance.configuration else {
            completion(.failure(GoogleAuthError.notConfigured))
            return
        }
        GIDSignIn.sharedInstance.configuration = configuration
        guard let presenter = Self.topViewController() else {
            completion(.failure(GoogleAuthError.noPresenter))
            return
        }
        GIDSignIn.sharedInstance.signIn(withPresenting: presenter) { result, error in
            if let error {
                completion(.failure(Self.friendlyError(error)))
                return
            }
            guard let user = result?.user else {
                completion(.failure(GoogleAuthError.missingUser))
                return
            }
            let profile = GoogleUserProfile(
                userID: user.userID ?? "",
                name: user.profile?.name ?? "",
                email: user.profile?.email ?? "",
                photoURL: user.profile?.imageURL(withDimension: 160)
            )
            completion(.success(profile))
        }
    }

    /// 登出当前会话（仅清理本地 SDK 会话）
    func signOut() {
        GIDSignIn.sharedInstance.signOut()
    }

    /// 把 SDK 错误转成用户友好的提示（区分取消与网络错误）
    private static func friendlyError(_ error: Error) -> Error {
        if let gidError = error as? GIDSignInError, gidError.code == .canceled {
            return GoogleAuthError.canceled
        }
        if error is URLError {
            return GoogleAuthError.network
        }
        return error
    }

    /// 读取客户端配置：GoogleService-Info.plist 优先，Info.plist GoogleClientID 兜底
    private static func loadConfiguration() -> GIDConfiguration? {
        if let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
           let dict = NSDictionary(contentsOfFile: path) as? [String: Any],
           let clientID = dict["CLIENT_ID"] as? String,
           !clientID.isEmpty {
            return GIDConfiguration(clientID: clientID)
        }
        if let clientID = Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String,
           !clientID.isEmpty {
            return GIDConfiguration(clientID: clientID)
        }
        return nil
    }

    /// 获取当前最顶层的视图控制器（用于弹出 Google 授权界面）
    private static func topViewController() -> UIViewController? {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
            let root = windowScene.keyWindow?.rootViewController
        else { return nil }
        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}
