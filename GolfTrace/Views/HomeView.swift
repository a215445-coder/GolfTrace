import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject private var session: AppSession
    @State private var pickedItem: PhotosPickerItem?

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
        .overlay {
            if session.isProcessing {
                processingOverlay
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
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            Task { await importPickedVideo(item) }
        }
    }

    private var homeContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("记录球的飞行轨迹")
                        .font(.largeTitle.bold())
                    Text("把手机固定好，让球飞过画面。识别失败时可以暂停后点选球的位置。")
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 12) {
                    CameraRecorderButton { url in
                        session.ingestVideo(from: url)
                    }

                    PhotosPicker(selection: $pickedItem, matching: .videos, photoLibrary: .shared()) {
                        Label("从相册选择", systemImage: "photo.on.rectangle")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
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
                                    Image(systemName: shot.trace.points.isEmpty ? "circle.slash" : "point.topleft.down.to.point.bottomright.curvepath")
                                    VStack(alignment: .leading) {
                                        Text(shot.displayTitle)
                                        Text(shot.trace.points.isEmpty ? "无线路" : "\(shot.trace.points.count) 个点")
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
    }

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text(session.processingMessage)
                    .font(.headline)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private func importPickedVideo(_ item: PhotosPickerItem) async {
        do {
            guard let movie = try await item.loadTransferable(type: ImportedMovie.self) else {
                session.errorMessage = "无法读取这段视频"
                return
            }
            session.ingestVideo(from: movie.url)
        } catch {
            session.errorMessage = error.localizedDescription
        }
        pickedItem = nil
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
