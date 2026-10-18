import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct CameraRecorderButton: View {
    var onRecorded: (URL) -> Void
    @State private var isPresented = false
    @State private var cameraUnavailable = false

    var body: some View {
        Button {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                isPresented = true
            } else {
                cameraUnavailable = true
            }
        } label: {
            Label("拍摄视频", systemImage: "video.fill")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 52)
                .foregroundStyle(.white)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
        }
        .sheet(isPresented: $isPresented) {
            CameraRecorder(onRecorded: onRecorded)
                .ignoresSafeArea()
        }
        .alert("模拟器没有相机", isPresented: $cameraUnavailable) {
            Button("好", role: .cancel) {}
        } message: {
            Text("请用真机拍摄，或从相册选择一段挥杆视频。")
        }
    }
}

struct CameraRecorder: UIViewControllerRepresentable {
    var onRecorded: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(onRecorded: onRecorded, dismiss: dismiss)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.movie.identifier]
        picker.cameraCaptureMode = .video
        picker.videoQuality = .typeHigh
        picker.delegate = context.coordinator
        picker.videoMaximumDuration = 20
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onRecorded: (URL) -> Void
        let dismiss: DismissAction

        init(onRecorded: @escaping (URL) -> Void, dismiss: DismissAction) {
            self.onRecorded = onRecorded
            self.dismiss = dismiss
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let url = info[.mediaURL] as? URL {
                onRecorded(url)
            }
            dismiss()
        }
    }
}
