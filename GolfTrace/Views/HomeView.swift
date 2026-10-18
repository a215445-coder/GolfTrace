import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject private var session: AppSession
    @State private var pickedVideo: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            Group {
                if session.route == .review, session.currentShot != nil {
                    ReviewView()
                } else {
                    homeContent
                }
            }
        }
        .alert("出错了", isPresented: Binding(
            get: { session.errorMessage != nil },
            set: { if !$0 { session.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { session.errorMessage = nil }
        } message: {
            Text(session.errorMessage ?? "")
        }
        .onChange(of: pickedVideo) { _, item in
            guard let item else { return }
            Task { await importPicked(item) }
        }
        .onAppear {
#if DEBUG
            // 仅调试用：-autoOpen 启动时直接打开最近一条记录（配合自动化截图检查）
            if ProcessInfo.processInfo.arguments.contains("-autoOpen"),
               let first = session.library.first {
                session.open(first)
            }
#endif
        }
    }

    private var homeContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("记录球的飞行轨迹")
                        .font(.largeTitle.bold())
                    Text("导入挥杆视频，在球经过的位置标记关键点，自动生成平滑的飞行曲线。")
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 12) {
                    CameraRecorderButton { url in
                        session.importVideo(from: url)
                    }

                    PhotosPicker(selection: $pickedVideo, matching: .videos, photoLibrary: .shared()) {
                        Label("从相册选择视频", systemImage: "video.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                }

                if !session.library.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("最近记录")
                            .font(.title3.bold())
                        ForEach(session.library) { shot in
                            Button {
                                session.open(shot)
                            } label: {
                                HStack {
                                    Image(systemName: shot.mediaType == .image ? "photo" : "video")
                                    VStack(alignment: .leading) {
                                        Text(shot.displayTitle)
                                        Text(shot.trace.points.isEmpty ? "无轨迹" : "\(shot.trace.points.count) 个关键点")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.tertiary)
                                }
                                .padding()
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    session.delete(shot)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("GolfTrace")
        .overlay(alignment: .bottom) {
            // 底部渐进模糊：从上透明渐入到模糊，不拦截触摸
            Rectangle()
                .fill(.ultraThinMaterial)
                .frame(height: 120)
                .mask {
                    LinearGradient(
                        colors: [.clear, .white],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .allowsHitTesting(false)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private func importPicked(_ item: PhotosPickerItem) async {
        do {
            guard let movie = try await item.loadTransferable(type: ImportedMovie.self) else {
                session.errorMessage = "无法读取这段视频"
                return
            }
            session.importVideo(from: movie.url)
        } catch {
            session.errorMessage = error.localizedDescription
        }
        pickedVideo = nil
    }
}

struct ImportedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let accessed = received.file.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    received.file.stopAccessingSecurityScopedResource()
                }
            }
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("import-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: destination)
            return ImportedMovie(url: destination)
        }
    }
}
