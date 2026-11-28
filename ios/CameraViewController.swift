import AVFoundation
import UIKit

final class CameraViewController: UIViewController {

    private let streamer: CameraStreamer
    private let previewLayer: AVCaptureVideoPreviewLayer
    private let statusLabel = UILabel()
    private let diagnosticsLabel = UILabel()
    private let orientationControl = UISegmentedControl(items: ["Landscape", "Portrait"])
    private let capabilitiesButton = UIButton(type: .system)
    private let presetControl = UISegmentedControl(items: StreamPreset.allCases.map(\.title))
    private var confirmedPreset = StreamPreset.stored
    private let adviceBanner = UIStackView()
    private let adviceLabel = UILabel()
    private var advisedPreset: StreamPreset?
    private let wifiSwitch = UISwitch()
    private let wifiRow = UIStackView()
    private var didStart = false
    private var confirmedOutputOrientation: OutputOrientation = .landscape
    // T5.9: Cinematic controls, shown only while a Cinematic preset runs.
    private let focusView = UIView()
    private let cinematicRow = UIStackView()
    private let apertureSlider = UISlider()
    private let apertureLabel = UILabel()
    private let cinematicNoteLabel = UILabel()

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
        // T5.9: taps on the preview set the Cinematic focus. The view sits under
        // every control, so taps on the controls never reach it.
        focusView.translatesAutoresizingMaskIntoConstraints = false
        focusView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(previewTapped(_:))))
        focusView.addGestureRecognizer(UILongPressGestureRecognizer(target: self,
                                                                    action: #selector(previewLongPressed(_:))))
        view.addSubview(focusView)
        NSLayoutConstraint.activate([
            focusView.topAnchor.constraint(equalTo: view.topAnchor),
            focusView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            focusView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            focusView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

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
        diagnosticsLabel.text = "\(StreamPreset.stored.rawValue) verification pending"
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

        // T5.4: output quality preset (720p / 1080p / 4K at 60 fps; T5.9 Cinematic at 30 fps).
        presetControl.selectedSegmentIndex = StreamPreset.allCases.firstIndex(of: confirmedPreset) ?? 0
        presetControl.selectedSegmentTintColor = .systemBlue
        presetControl.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        presetControl.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        presetControl.translatesAutoresizingMaskIntoConstraints = false
        presetControl.addTarget(self, action: #selector(presetChanged), for: .valueChanged)
        view.addSubview(presetControl)

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
        // T5.7: a recommendation only. The user taps Switch; the app never
        // changes the resolution by itself.
        adviceLabel.textColor = .white
        adviceLabel.font = .preferredFont(forTextStyle: .subheadline)
        adviceLabel.numberOfLines = 0
        var switchConfig = UIButton.Configuration.filled()
        switchConfig.title = "Switch"
        let switchButton = UIButton(configuration: switchConfig)
        switchButton.addTarget(self, action: #selector(acceptAdvice), for: .touchUpInside)
        var dismissConfig = UIButton.Configuration.plain()
        dismissConfig.title = "Dismiss"
        dismissConfig.baseForegroundColor = .white
        let dismissButton = UIButton(configuration: dismissConfig)
        dismissButton.addTarget(self, action: #selector(dismissAdvice), for: .touchUpInside)
        let adviceButtons = UIStackView(arrangedSubviews: [switchButton, dismissButton])
        adviceButtons.axis = .horizontal
        adviceButtons.spacing = 12
        adviceButtons.distribution = .fillEqually
        adviceBanner.axis = .vertical
        adviceBanner.spacing = 8
        adviceBanner.addArrangedSubview(adviceLabel)
        adviceBanner.addArrangedSubview(adviceButtons)
        adviceBanner.isLayoutMarginsRelativeArrangement = true
        adviceBanner.layoutMargins = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        adviceBanner.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        adviceBanner.layer.cornerRadius = 10
        adviceBanner.isHidden = true
        adviceBanner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(adviceBanner)
        NSLayoutConstraint.activate([
            adviceBanner.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            adviceBanner.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            adviceBanner.bottomAnchor.constraint(equalTo: capabilitiesButton.topAnchor, constant: -10),
        ])
        view.addSubview(wifiRow)
        // T5.9: simulated aperture, applied through CameraStreamer only.
        apertureLabel.textColor = .white
        apertureLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        apertureSlider.addTarget(self, action: #selector(apertureChanged), for: .valueChanged)
        apertureSlider.widthAnchor.constraint(equalToConstant: 140).isActive = true
        cinematicRow.axis = .horizontal
        cinematicRow.alignment = .center
        cinematicRow.spacing = 8
        cinematicRow.addArrangedSubview(apertureLabel)
        cinematicRow.addArrangedSubview(apertureSlider)
        cinematicRow.isLayoutMarginsRelativeArrangement = true
        cinematicRow.layoutMargins = UIEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
        cinematicRow.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        cinematicRow.layer.cornerRadius = 10
        cinematicRow.isHidden = true
        cinematicRow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cinematicRow)
        cinematicNoteLabel.textColor = .systemYellow
        cinematicNoteLabel.font = .preferredFont(forTextStyle: .subheadline)
        cinematicNoteLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        cinematicNoteLabel.isHidden = true
        cinematicNoteLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cinematicNoteLabel)
        NSLayoutConstraint.activate([
            cinematicRow.topAnchor.constraint(equalTo: presetControl.bottomAnchor, constant: 8),
            cinematicRow.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            cinematicRow.trailingAnchor.constraint(lessThanOrEqualTo: wifiRow.leadingAnchor, constant: -8),
            cinematicNoteLabel.topAnchor.constraint(equalTo: cinematicRow.bottomAnchor, constant: 6),
            cinematicNoteLabel.leadingAnchor.constraint(equalTo: cinematicRow.leadingAnchor),
        ])
        NSLayoutConstraint.activate([
            presetControl.topAnchor.constraint(equalTo: orientationControl.bottomAnchor, constant: 8),
            presetControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            presetControl.widthAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.widthAnchor,
                                                  constant: -32),
            wifiRow.topAnchor.constraint(equalTo: presetControl.bottomAnchor, constant: 8),
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
        streamer.onPresetChanged = { [weak self] preset in
            guard let self else { return }
            self.confirmedPreset = preset
            self.adviceBanner.isHidden = true
            self.advisedPreset = nil
            self.presetControl.selectedSegmentIndex = StreamPreset.allCases.firstIndex(of: preset) ?? 0
        }
        streamer.onAdvice = { [weak self] preset, reason in
            guard let self, preset != self.confirmedPreset else { return }
            self.advisedPreset = preset
            self.adviceLabel.text = "\(preset.rawValue) recommended — \(reason)."
            self.adviceBanner.isHidden = false
        }
        streamer.onCinematicAperture = { [weak self] aperture in
            guard let self else { return }
            self.cinematicRow.isHidden = aperture == nil
            guard let aperture else { return }
            self.apertureSlider.minimumValue = aperture.range.lowerBound
            self.apertureSlider.maximumValue = aperture.range.upperBound
            self.apertureSlider.value = aperture.value
            self.updateApertureLabel()
        }
        streamer.onCinematicNote = { [weak self] note in
            self?.cinematicNoteLabel.text = note.map { " \($0) " }
            self?.cinematicNoteLabel.isHidden = note == nil
        }
        streamer.onPresetAvailability = { [weak self] available in
            guard let self else { return }
            for (index, preset) in StreamPreset.allCases.enumerated() {
                self.presetControl.setEnabled(available.contains(preset), forSegmentAt: index)
            }
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

    @objc private func acceptAdvice() {
        guard let preset = advisedPreset else { return }
        adviceBanner.isHidden = true
        advisedPreset = nil
        streamer.setPreset(preset)
    }

    @objc private func dismissAdvice() {
        adviceBanner.isHidden = true
        advisedPreset = nil
    }

    @objc private func presetChanged() {
        let index = presetControl.selectedSegmentIndex
        guard StreamPreset.allCases.indices.contains(index) else { return }
        // Keep the displayed choice at the confirmed value until the camera
        // accepts the format; onPresetChanged moves it.
        presetControl.selectedSegmentIndex = StreamPreset.allCases.firstIndex(of: confirmedPreset) ?? 0
        streamer.setPreset(StreamPreset.allCases[index])
    }

    @objc private func apertureChanged() {
        updateApertureLabel()
        streamer.setCinematicAperture(apertureSlider.value)
    }

    private func updateApertureLabel() {
        apertureLabel.text = String(format: "f/%.1f", apertureSlider.value)
    }

    @objc private func previewTapped(_ recognizer: UITapGestureRecognizer) {
        focusCinematic(from: recognizer, fixed: false)
    }

    @objc private func previewLongPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        focusCinematic(from: recognizer, fixed: true)
    }

    /// Tap: track the subject under the finger. Long press: hold focus there.
    private func focusCinematic(from recognizer: UIGestureRecognizer, fixed: Bool) {
        guard confirmedPreset.isCinematic else { return }
        let layerPoint = recognizer.location(in: view)
        streamer.focusCinematic(at: previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint),
                                fixed: fixed)
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
