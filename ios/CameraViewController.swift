import AVFoundation
import UIKit

final class CameraViewController: UIViewController {

    private let streamer: CameraStreamer
    private let previewLayer: AVCaptureVideoPreviewLayer
    private let statusLabel = UILabel()
    private let diagnosticsLabel = UILabel()
    private var didStart = false

    init(streamer: CameraStreamer) {
        self.streamer = streamer
        previewLayer = AVCaptureVideoPreviewLayer(session: streamer.captureSession)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)

        statusLabel.text = "iPhone Camera Stream 0.4\nStarting camera…"
        statusLabel.textColor = .white
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.layer.cornerRadius = 10
        statusLabel.clipsToBounds = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        diagnosticsLabel.text = "4K60 verification pending"
        diagnosticsLabel.textColor = .white
        diagnosticsLabel.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.72)
        diagnosticsLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        diagnosticsLabel.textAlignment = .center
        diagnosticsLabel.numberOfLines = 0
        diagnosticsLabel.layer.cornerRadius = 10
        diagnosticsLabel.clipsToBounds = true
        diagnosticsLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(diagnosticsLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            statusLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            diagnosticsLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            diagnosticsLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            diagnosticsLabel.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -10),
            diagnosticsLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 66),
        ])

        streamer.onStatus = { [weak self] message in
            self?.statusLabel.text = message
        }
        streamer.onDiagnostics = { [weak self] text in
            self?.diagnosticsLabel.text = text
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStart else { return }
        didStart = true
        streamer.start()
    }
}
