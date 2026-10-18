import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var session: AppSession

    @State private var appeared = false

    var body: some View {
        ZStack {
            // 全屏背景：高尔夫海边日落壁纸，cover 铺满
            Image("LoginBackground")
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .ignoresSafeArea()

            // 轻柔深色渐变遮罩：顶部极浅、底部加深，保证文字清晰又不压暗壁纸
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.30), location: 0),
                    .init(color: .black.opacity(0.12), location: 0.28),
                    .init(color: .black.opacity(0.42), location: 0.62),
                    .init(color: .black.opacity(0.78), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                brandHeader
                    .padding(.top, 64)

                Spacer()

                welcomeSection

                Spacer()

                enterButton
                    .padding(.bottom, 64)
            }
            .padding(.horizontal, 28)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 18)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.7)) { appeared = true }
        }
    }

    // MARK: - 顶部品牌区

    private var brandHeader: some View {
        VStack(spacing: 14) {
            Image("LoginLogo")
                .resizable()
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
            Text("GolfTrace")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text("Your Game. Your Journey.")
                .font(.system(size: 13, weight: .regular))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.72))
                .textCase(.uppercase)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 14)
        .animation(.easeOut(duration: 0.7).delay(0.05), value: appeared)
    }

    // MARK: - 欢迎区

    private var welcomeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Welcome Back")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("Start your golf journey.")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.75))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 16)
        .animation(.easeOut(duration: 0.7).delay(0.18), value: appeared)
    }

    // MARK: - 进入主界面按钮

    private var enterButton: some View {
        Button {
            session.completeLogin()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "figure.golf")
                    .font(.system(size: 15, weight: .medium))
                Text("进入 GolfTrace")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .opacity(0.6)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: 54)
            .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(.white.opacity(0.14), lineWidth: 0.5)
            )
        }
        .buttonStyle(LoginPressStyle())
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 16)
        .animation(.easeOut(duration: 0.7).delay(0.32), value: appeared)
    }
}

// MARK: - 登录按钮按压反馈

struct LoginPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
