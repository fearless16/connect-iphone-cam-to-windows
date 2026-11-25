import AVFoundation
import UIKit

final class CameraViewController: UIViewController {

    private let streamer: CameraStreamer
    private let previewLayer: AVCaptureVideoPreviewLayer
    private let statusLabel = UILabel()
    private let diagnosticsLabel = UILabel()
    private let orientationControl = UISegmentedControl(items: ["Landscape", "Portrait"])
    private let capabilitiesButton = UIButton(type: .system)
    private let wifiSwitch = UISwitch()
    private let wifiRow = UIStackView()
    private var didStart = false
    private var confirmedOutputOrientation: OutputOrientation = .landscape

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

        orientationControl.selectedSegmentIndex = 0
        orientationControl.selectedSegmentTintColor = .systemBlue
        orientationControl.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        orientationControl.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        orientationControl.translatesAutoresizingMaskIntoConstraints = false
        orientationControl.addTarget(self, action: #selector(outputOrientationChanged), for: .valueChanged)
        view.addSubview(orientationControl)

        // T5.2: one-shot device capability report, read-only.
        var capabilitiesConfig = UIButton.Configuration.plain()
        capabilitiesConfig.title = "Capabilities"
        capabilitiesConfig.baseForegroundColor = .white
        capabilitiesConfig.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
        capabilitiesButton.configuration = capabilitiesConfig
        capabilitiesButton.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        capabilitiesButton.layer.cornerRadius = 10
        capabilitiesButton.translatesAutoresizingMaskIntoConstraints = false
        capabilitiesButton.addTarget(self, action: #selector(showCapabilities), for: .touchUpInside)
        view.addSubview(capabilitiesButton)

        // T3.1: Wi-Fi streaming is opt-in and off by default. The switch talks to
        // CameraStreamer only.
        let wifiLabel = UILabel()
        wifiLabel.text = "Wi-Fi"
        wifiLabel.textColor = .white
        wifiLabel.font = .preferredFont(forTextStyle: .subheadline)
        wifiSwitch.isOn = CameraStreamer.isWiFiEnabledStored
        wifiSwitch.addTarget(self, action: #selector(wifiSwitchChanged), for: .valueChanged)
        wifiRow.axis = .horizontal
        wifiRow.alignment = .center
        wifiRow.spacing = 8
        wifiRow.addArrangedSubview(wifiLabel)
        wifiRow.addArrangedSubview(wifiSwitch)
        wifiRow.isLayoutMarginsRelativeArrangement = true
        wifiRow.layoutMargins = UIEdgeInsets(top: 4, left: 12, bottom: 4, right: 8)
        wifiRow.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        wifiRow.layer.cornerRadius = 10
        wifiRow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(wifiRow)
        NSLayoutConstraint.activate([
            wifiRow.topAnchor.constraint(equalTo: orientationControl.bottomAnchor, constant: 8),
            wifiRow.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            capabilitiesButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            capabilitiesButton.bottomAnchor.constraint(equalTo: diagnosticsLabel.topAnchor, constant: -10),
            orientationControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            orientationControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            orientationControl.widthAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.widthAnchor,
                                                       constant: -32),
            statusLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            statusLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            diagnosticsLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            diagnosticsLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            diagnosticsLabel.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -10),
            diagnosticsLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 66),
        ])

        streamer.onStreamHealth = { [weak self] status in
            self?.statusLabel.text = status
        }
        streamer.onDiagnostics = { [weak self] text in
            self?.diagnosticsLabel.text = text
        }
        streamer.onOutputOrientation = { [weak self] orientation in
            self?.confirmedOutputOrientation = orientation
            self?.orientationControl.selectedSegmentIndex = orientation == .portrait ? 1 : 0
            self?.updatePreviewOrientation(orientation)
        }
        updatePreviewOrientation(.landscape)
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

    @objc private func outputOrientationChanged() {
        let orientation: OutputOrientation = orientationControl.selectedSegmentIndex == 1 ? .portrait : .landscape
        // Keep the displayed choice at the confirmed value until the capture
        // connection accepts the requested rotation.
        orientationControl.selectedSegmentIndex = confirmedOutputOrientation == .portrait ? 1 : 0
        streamer.setOutputOrientation(orientation)
    }

    @objc private func wifiSwitchChanged() {
        streamer.setWiFiEnabled(wifiSwitch.isOn)
    }

    @objc private func showCapabilities() {
        capabilitiesButton.isEnabled = false
        streamer.capabilityReport { [weak self] text in
            guard let self else { return }
            self.capabilitiesButton.isEnabled = true
            self.present(CapabilityReportViewController(text: text), animated: true)
        }
    }

    private func updatePreviewOrientation(_ orientation: OutputOrientation) {
        guard let connection = previewLayer.connection,
              connection.isVideoRotationAngleSupported(orientation.rotationAngle) else { return }
        connection.videoRotationAngle = orientation.rotationAngle
    }
}

/// Read-only, copyable text of the capability report (T5.2).
private final class CapabilityReportViewController: UIViewController {

    private let text: String

    init(text: String) {
        self.text = text
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let textView = UITextView()
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.text = text
        textView.translatesAutoresizingMaskIntoConstraints = false

        let copyButton = UIButton(type: .system)
        copyButton.setTitle("Copy", for: .normal)
        copyButton.addTarget(self, action: #selector(copyReport), for: .touchUpInside)
        let closeButton = UIButton(type: .system)
        closeButton.setTitle("Close", for: .normal)
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        let buttons = UIStackView(arrangedSubviews: [copyButton, closeButton])
        buttons.distribution = .fillEqually
        buttons.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(buttons)
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            buttons.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            buttons.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            textView.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 8),
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])
    }

    @objc private func copyReport() {
        UIPasteboard.general.string = text
    }

    @objc private func close() {
        dismiss(animated: true)
    }
}
