#if targetEnvironment(macCatalyst)
import UIKit
import AVFoundation
import CoreImage

/// Catalyst has no VisionKit document-camera UI. Capture pages on the Mac and
/// return them to the same local OCR/region-selection pipeline used on iOS.
final class MacDocumentCameraViewController: UIViewController {
    var onScan: ([UIImage]) -> Void = { _ in }
    var onCancel: () -> Void = {}
    private let camera = MacPageCamera()
    private let preview = AVCaptureVideoPreviewLayer()
    private let message = UILabel()
    private let thumbnail = UIImageView()
    private let capture = UIButton(type: .system)
    private let undo = UIButton(type: .system)
    private let done = UIButton(type: .system)
    private var pages: [UIImage] = []
    private var attached = false
    private var capturing = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        preview.session = camera.session
        preview.videoGravity = .resizeAspect
        view.layer.addSublayer(preview)
        message.textAlignment = .center
        message.numberOfLines = 0
        message.font = .preferredFont(forTextStyle: .body)
        message.backgroundColor = .secondarySystemBackground
        thumbnail.contentMode = .scaleAspectFit
        thumbnail.accessibilityIdentifier = "macCameraLastPage"
        let cancel = button(AppLocalized("取消"), id: "macCameraCancel", action: #selector(cancelCapture))
        configure(capture, title: AppLocalized("拍照"), id: "macCameraCapture", action: #selector(takePhoto))
        configure(undo, title: AppLocalized("撤销上一页"), id: "macCameraUndo", action: #selector(undoPage))
        configure(done, title: AppLocalized("完成"), id: "macCameraDone", action: #selector(finishCapture))
        let controls = UIStackView(arrangedSubviews: [cancel, undo, capture, done])
        controls.axis = .horizontal
        controls.distribution = .fillEqually
        controls.spacing = 12
        for item in [message, thumbnail, controls] { item.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(item) }
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            controls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            controls.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            message.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            message.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            message.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -12),
            thumbnail.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            thumbnail.bottomAnchor.constraint(equalTo: message.topAnchor, constant: -12),
            thumbnail.widthAnchor.constraint(equalToConstant: 100),
            thumbnail.heightAnchor.constraint(equalToConstant: 120)
        ])
        updateControls()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview.frame = CGRect(x: 0, y: view.safeAreaInsets.top, width: view.bounds.width,
                               height: max(0, message.frame.minY - view.safeAreaInsets.top - 12))
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        attached = true
        camera.onResult = { [weak self] result in
            guard let self, self.attached else { return }
            self.capturing = false
            switch result {
            case .success(let image):
                if let image { self.pages.append(image); self.thumbnail.image = image }
                self.message.text = self.pages.isEmpty ? AppLocalized("将页面放在取景框中，可连续拍摄多页。")
                    : String(format: AppLocalized("已拍摄 %lld 页"), self.pages.count)
            case .failure:
                self.message.text = AppLocalized("无法使用相机。请检查相机连接，或从文件导入图片。")
            }
            self.updateControls()
        }
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized { camera.start() }
        else { message.text = AppLocalized("拍照需要相机权限。请在系统设置的隐私与安全性中允许访问。") }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stop()
    }

    func stop() { attached = false; camera.onResult = nil; camera.stop() }

    private func button(_ title: String, id: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        configure(button, title: title, id: id, action: action)
        return button
    }
    private func configure(_ button: UIButton, title: String, id: String, action: Selector) {
        button.setTitle(title, for: .normal)
        button.accessibilityIdentifier = id
        button.addTarget(self, action: action, for: .touchUpInside)
    }
    private func updateControls() {
        capture.isEnabled = !capturing && pages.count < 20
        done.isEnabled = !capturing && !pages.isEmpty
        undo.isEnabled = !capturing && !pages.isEmpty
    }

    @objc private func takePhoto() {
        guard !capturing, pages.count < 20 else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            capturing = true; updateControls(); camera.capture()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.attached else { return }
                    if granted { self.camera.start() }
                    else { self.message.text = AppLocalized("拍照需要相机权限。请在系统设置的隐私与安全性中允许访问。") }
                }
            }
        default: message.text = AppLocalized("拍照需要相机权限。请在系统设置的隐私与安全性中允许访问。")
        }
    }
    @objc private func undoPage() {
        guard !capturing, !pages.isEmpty else { return }
        pages.removeLast(); thumbnail.image = pages.last
        message.text = String(format: AppLocalized("已拍摄 %lld 页"), pages.count)
        updateControls()
    }
    @objc private func cancelCapture() { stop(); onCancel() }
    @objc private func finishCapture() {
        guard !capturing, !pages.isEmpty else { return }
        let result = pages; stop(); onScan(result)
    }
}

/// All session mutation and image processing runs off the UI thread. Stopping
/// is ordered after any in-flight capture and late results are ignored by UI.
private final class MacPageCamera: NSObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    var onResult: ((Result<UIImage?, Error>) -> Void)?
    private let queue = DispatchQueue(label: "ai.castreader.mac-camera", qos: .userInitiated)
    private let output = AVCapturePhotoOutput()
    private var configured = false
    private var active = false
    private enum CaptureError: Error { case unavailable, invalidImage }

    func start() { queue.async { self.active = true; self.configureAndStart() } }
    func stop() { queue.async { self.active = false; if self.session.isRunning { self.session.stopRunning() } } }
    func capture() {
        queue.async {
            guard self.active else { self.deliver(.failure(CaptureError.unavailable)); return }
            guard self.configureAndStart() else { return }
            self.output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }
    @discardableResult
    private func configureAndStart() -> Bool {
        guard active else { return false }
        if !configured {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                deliver(.failure(CaptureError.unavailable)); return false
            }
            session.beginConfiguration()
            session.sessionPreset = .photo
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration(); deliver(.failure(CaptureError.unavailable)); return false
            }
            session.addInput(input); session.addOutput(output)
            session.commitConfiguration(); configured = true
        }
        if !session.isRunning { session.startRunning(); deliver(.success(nil)) }
        return true
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        queue.async {
            guard self.active else { return }
            guard error == nil, let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
                self.deliver(.failure(error ?? CaptureError.invalidImage)); return
            }
            self.deliver(.success(Self.preparePage(image)))
        }
    }
    private func deliver(_ result: Result<UIImage?, Error>) {
        DispatchQueue.main.async { self.onResult?(result) }
    }

    private static func preparePage(_ input: UIImage) -> UIImage {
        let image = ImagePreprocessor.documentCorrected(input.fixedOrientation())
        guard var page = CIImage(image: image) else { return image }
        // Bound twenty-page sessions without discarding OCR detail.
        let scale = min(1, 2560 / max(page.extent.width, page.extent.height))
        page = page.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let pixels = CIContext().createCGImage(page, from: page.extent) else { return image }
        return UIImage(cgImage: pixels)
    }
}
#endif
