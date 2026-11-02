import AppKit
import SwiftUI
import WMCore

/// Drives one recording: owns the `ActionRecorder`, shows a small floating "Recording…" panel that never
/// takes focus (so the user can work in other apps), and hands the recorded steps back on Stop.
@MainActor
final class RecordingController: ObservableObject {
    @Published private(set) var stepCount = 0
    private let recorder = ActionRecorder(source: EventTapSource(), inspector: SystemRecorderInspector())
    private var panel: NSPanel?
    private var timer: Timer?
    private var onFinish: (([ActionStep], Bool) -> Void)?

    var isRecording: Bool { recorder.isRecording }

    /// Starts recording. Returns false (and shows nothing) when the event tap could not start.
    func start(onFinish: @escaping ([ActionStep], Bool) -> Void) -> Bool {
        guard !recorder.isRecording, recorder.start() else { return recorder.isRecording }
        self.onFinish = onFinish
        stepCount = 0
        showPanel()
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepCount = self?.recorder.steps.count ?? 0 }
        }
        return true
    }

    func stop() {
        guard recorder.isRecording else { return }
        timer?.invalidate(); timer = nil
        let steps = recorder.stop()
        let skipped = recorder.skippedSecureInput
        panel?.orderOut(nil); panel = nil
        let done = onFinish; onFinish = nil
        done?(steps, skipped)
    }

    private func showPanel() {
        let host = NSHostingView(rootView: RecordingPanelView(controller: self) { [weak self] in self?.stop() })
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 44),
                            styleMask: [.nonactivatingPanel, .titled, .utilityWindow, .hudWindow],
                            backing: .buffered, defer: false)
        panel.title = "Recording"
        panel.contentView = host
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setContentSize(host.fittingSize)
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.maxX - panel.frame.width - 24, y: f.maxY - panel.frame.height - 24))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

private struct RecordingPanelView: View {
    @ObservedObject var controller: RecordingController
    let stop: () -> Void

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "record.circle.fill").foregroundStyle(.red)
            Text("Recording… \(controller.stepCount) step\(controller.stepCount == 1 ? "" : "s")")
                .font(.wmCaption.monospacedDigit()).lineLimit(1)
            Spacer(minLength: Spacing.xs)
            Button("Stop", action: stop).help("Stop recording and add the steps to the action")
        }
        .padding(Spacing.s)
        .frame(width: 240)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording in progress")
    }
}

enum RecordingPermission {
    /// Explains the permission a failed start needs and offers to open the pane; never changes settings.
    @MainActor static func showStartFailedAlert() {
        let alert = NSAlert()
        alert.messageText = "Recording could not start"
        alert.informativeText = "Windows Manager listens for clicks and key presses to record steps. Turn it on in System Settings > Privacy & Security > Input Monitoring (and Accessibility, which is also needed to identify what you click), then try again."
        alert.addButton(withTitle: "Open Input Monitoring Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}
