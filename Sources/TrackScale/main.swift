import AppKit
import OpenMultitouchSupport

@MainActor
final class TrackpadWeightView: NSView {
    private let manager = OMSManager.shared
    private var task: Task<Void, Never>?

    private var baselinePressure: Float = 0
    private var currentPressure: Float = 0
    private var stabilizedPressure: Float = 0
    private var heldPressure: Float = 0
    private var lastTouchCount = 0
    private var didLockBaseline = false
    private var objectConsecutiveCount = 0
    private var isObjectDetected = false
    private var pressureHistory: [Float] = []
    private var signalHistory: [Float] = []
    private var baselineHistory: [Float] = []
    private var lastSignalAt: Date?
    private var listeningStartedAt: Date?
    private var signalSource = "pressure"
    private var totalToGramScale: Float = 0.02

    private let historyWindowSize = 24
    private let baselineWindowSize = 6
    private let baselineLockTimeoutSeconds: TimeInterval = 1.5
    private let noSignalHoldSeconds: TimeInterval = 2.0
    private let objectDetectThreshold: Float = 0.35
    private let objectReleaseThreshold: Float = 0.12
    private let detectionConsecutiveNeeded = 2

    private let diagnosticsLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Touches: 0 | Source: pressure")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        return label
    }()

    private let titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "TrackScale")
        label.font = NSFont.systemFont(ofSize: 28, weight: .bold)
        label.alignment = .center
        return label
    }()

    private let statusLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Status: Starting sensor stream...")
        label.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        return label
    }()

    private let weightLabel: NSTextField = {
        let label = NSTextField(labelWithString: "0.0 g")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 52, weight: .bold)
        label.alignment = .center
        return label
    }()

    private let pressureLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Pressure: 0.000")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        return label
    }()

    private let calibrationLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Mode: Fixed zero baseline (no calibration)")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        return label
    }()

    private let noteLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Best effort without finger contact; conductive contact improves detection.")
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .systemOrange
        label.alignment = .center
        return label
    }()

    private lazy var resetBaselineButton: NSButton = {
        let button = NSButton(title: "Reset Baseline", target: self, action: #selector(resetBaseline))
        button.bezelStyle = .rounded
        return button
    }()

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
        startListening()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
        startListening()
    }

    deinit {
        task?.cancel()
        _ = manager.stopListening()
    }

    @objc
    private func resetBaseline() {
        baselinePressure = stabilizedPressure
        didLockBaseline = true
        updateCalibrationLabel()
        updateWeightLabel()
        statusLabel.stringValue = "Status: Baseline reset"
    }

    private func startListening() {
        // Prefer built-in trackpad explicitly; this mirrors the demo behavior more closely.
        let devices = manager.availableDevices
        if let builtIn = devices.first(where: { $0.isBuiltIn }) {
            _ = manager.selectDevice(builtIn)
        } else if let first = devices.first {
            _ = manager.selectDevice(first)
        }

        if !manager.startListening() {
            statusLabel.stringValue = "Status: Failed to start trackpad stream"
            return
        }

        listeningStartedAt = Date()
        statusLabel.stringValue = "Status: Listening"

        task = Task { [weak self, manager] in
            for await touchData in manager.touchDataStream {
                await MainActor.run {
                    self?.handleTouchData(touchData)
                }
            }
        }
    }

    private func handleTouchData(_ touchData: [OMSTouchData]) {
        if !touchData.isEmpty {
            let pressure = touchData.map(\ .pressure).max() ?? 0
            let total = touchData.map(\ .total).max() ?? 0

            if total > 0, pressure > 0.05 {
                let instantaneousScale = pressure / total
                totalToGramScale = (0.15 * instantaneousScale) + (0.85 * totalToGramScale)
            }

            let totalAsGrams = total * totalToGramScale
            let frameSignal = max(pressure, totalAsGrams)
            signalSource = pressure >= totalAsGrams ? "pressure" : "total"

            currentPressure = frameSignal
            lastSignalAt = Date()
            lastTouchCount = touchData.count
            appendPressureSample(frameSignal)
            appendSignalSample(frameSignal)
            stabilizedPressure = stabilizedFromSignalWindow()
            heldPressure = stabilizedPressure
            statusLabel.stringValue = "Status: Signal received"
        } else {
            currentPressure = 0
            lastTouchCount = 0

            if let lastSignalAt, Date().timeIntervalSince(lastSignalAt) <= noSignalHoldSeconds {
                stabilizedPressure = heldPressure
                statusLabel.stringValue = "Status: Holding recent signal"
            } else {
                stabilizedPressure = 0
                pressureHistory.removeAll(keepingCapacity: true)
                signalHistory.removeAll(keepingCapacity: true)
                objectConsecutiveCount = 0
                isObjectDetected = false
                if let listeningStartedAt,
                   Date().timeIntervalSince(listeningStartedAt) > 2.5,
                   !didLockBaseline {
                    statusLabel.stringValue = "Status: No sensor signal yet"
                } else {
                    statusLabel.stringValue = "Status: No touch signal"
                }
            }
        }

        pressureLabel.stringValue = String(format: "Pressure: %.3f", stabilizedPressure)
        diagnosticsLabel.stringValue = String(
            format: "Touches: %d | Source: %@ | k=%.4f",
            lastTouchCount,
            signalSource,
            totalToGramScale
        )

        if !didLockBaseline, !touchData.isEmpty {
            baselineHistory.append(stabilizedPressure)
            if baselineHistory.count > baselineWindowSize {
                baselineHistory.removeFirst(baselineHistory.count - baselineWindowSize)
            }

            if baselineHistory.count >= baselineWindowSize {
                baselinePressure = baselineFromHistory()
                didLockBaseline = true
                statusLabel.stringValue = "Status: Baseline locked"
                updateCalibrationLabel()
            } else {
                let hasTimedOut = listeningStartedAt.map {
                    Date().timeIntervalSince($0) >= baselineLockTimeoutSeconds
                } ?? false

                if hasTimedOut {
                    baselinePressure = baselineFromHistory()
                    didLockBaseline = true
                    statusLabel.stringValue = "Status: Baseline locked (quick)"
                    updateCalibrationLabel()
                } else {
                    statusLabel.stringValue = "Status: Capturing baseline..."
                }
            }
        }

        updateWeightLabel()
    }

    private func baselineFromHistory() -> Float {
        guard !baselineHistory.isEmpty else { return 0 }

        let sorted = baselineHistory.sorted()
        let take = max(1, sorted.count / 3)
        let lowBand = sorted.prefix(take)
        let avg = lowBand.reduce(0, +) / Float(lowBand.count)
        return avg
    }

    private func appendPressureSample(_ pressure: Float) {
        pressureHistory.append(pressure)

        if pressureHistory.count > historyWindowSize {
            pressureHistory.removeFirst(pressureHistory.count - historyWindowSize)
        }
    }

    private func appendSignalSample(_ signal: Float) {
        signalHistory.append(signal)

        if signalHistory.count > historyWindowSize {
            signalHistory.removeFirst(signalHistory.count - historyWindowSize)
        }
    }

    private func stabilizedFromWindow() -> Float {
        guard !pressureHistory.isEmpty else { return 0 }

        let sorted = pressureHistory.sorted()
        let trim = max(1, sorted.count / 10)

        if sorted.count <= 3 {
            return sorted.reduce(0, +) / Float(sorted.count)
        }

        let core = Array(sorted.dropFirst(trim).dropLast(trim))
        if core.isEmpty {
            return sorted.reduce(0, +) / Float(sorted.count)
        }

        return core.reduce(0, +) / Float(core.count)
    }

    private func stabilizedFromSignalWindow() -> Float {
        if signalHistory.isEmpty {
            return stabilizedFromWindow()
        }

        let sorted = signalHistory.sorted()
        let trim = max(1, sorted.count / 10)

        if sorted.count <= 3 {
            return sorted.reduce(0, +) / Float(sorted.count)
        }

        let core = Array(sorted.dropFirst(trim).dropLast(trim))
        if core.isEmpty {
            return sorted.reduce(0, +) / Float(sorted.count)
        }

        return core.reduce(0, +) / Float(core.count)
    }

    private func updateWeightLabel() {
        let base: Float
        if didLockBaseline {
            base = baselinePressure
        } else if !baselineHistory.isEmpty {
            // Show a provisional estimate so UI is responsive before full baseline lock.
            base = baselineFromHistory()
        } else {
            base = 0
        }

        // OpenMultitouchSupport pressure is treated as grams-like units with baseline subtraction.
        let grams = max(0, stabilizedPressure - base)

        if grams >= objectDetectThreshold {
            objectConsecutiveCount += 1
            if objectConsecutiveCount >= detectionConsecutiveNeeded {
                isObjectDetected = true
            }
        } else if grams <= objectReleaseThreshold {
            objectConsecutiveCount = 0
            isObjectDetected = false
        }

        if isObjectDetected {
            statusLabel.stringValue = "Status: Object detected"
        }

        weightLabel.stringValue = String(format: "%.1f g", grams)
    }

    private func updateCalibrationLabel() {
        if didLockBaseline {
            calibrationLabel.stringValue = String(format: "Mode: Fixed zero baseline=%.3f", baselinePressure)
        } else {
            calibrationLabel.stringValue = "Mode: Waiting for first signal"
        }
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let inputRow = NSStackView(views: [resetBaselineButton])
        inputRow.orientation = .horizontal
        inputRow.alignment = .centerY
        inputRow.spacing = 10

        let root = NSStackView(
            views: [titleLabel, statusLabel, weightLabel, pressureLabel, diagnosticsLabel, inputRow, calibrationLabel, noteLabel]
        )
        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 14
        root.translatesAutoresizingMaskIntoConstraints = false

        addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            root.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        updateCalibrationLabel()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let rect = NSRect(x: 0, y: 0, width: 700, height: 430)
        let window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "TrackScale"
        window.center()
        window.contentView = TrackpadWeightView(frame: rect)
        window.makeKeyAndOrderFront(nil)

        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
