import Foundation
import SwiftUI

@MainActor
final class SpeedTestCoordinator: ObservableObject {
    private struct MetricsSnapshot {
        var pingMs: Double?
        var jitterMs: Double?
        var testDownMbps: Double?
        var testUpMbps: Double?
        var activeRecord: SpeedTestRecord?
    }

    @Published private(set) var phase: SpeedTestPhase = .idle
    @Published private(set) var progress = SpeedTestProgress(phase: .idle)
    @Published private(set) var measuredPingMs: Double?
    @Published private(set) var measuredJitterMs: Double?
    @Published private(set) var hasDownloadReading = false
    @Published private(set) var hasUploadReading = false
    @Published private(set) var hasCompletedRun = false
    @Published private(set) var completedRecord: SpeedTestRecord?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRunning = false
    @Published var inspectedHistoryID: UUID?

    private let viewModel: MonitorViewModel
    private var activeTask: Task<SpeedTestResult, Error>?
    private var completionTask: Task<Void, Never>?
    private var activeRunID: UUID?
    private var metricsSnapshot: MetricsSnapshot?
    private var smoothedDownloadMbps = 0.0
    private var smoothedUploadMbps = 0.0
    private var speedScaleMax = 120.0

    init(viewModel: MonitorViewModel) {
        self.viewModel = viewModel
    }

    deinit {
        activeTask?.cancel()
        completionTask?.cancel()
    }

    var liveDownloadMbps: Double? {
        switch phase {
        case .download:
            progress.liveDownKbps / 1_000
        case .upload:
            progress.testDownMbps
        case .idle, .ping:
            nil
        }
    }

    var liveUploadMbps: Double? {
        phase == .upload ? progress.liveUpKbps / 1_000 : nil
    }

    var speedScale: Double { speedScaleMax }

    func startSpeedTest(gatewayURL: URL?) {
        guard phase == .idle, viewModel.canRunSpeedTest else { return }

        metricsSnapshot = MetricsSnapshot(
            pingMs: measuredPingMs ?? viewModel.activeSpeedTestRecord?.pingMs,
            jitterMs: measuredJitterMs ?? viewModel.activeSpeedTestRecord?.jitterMs,
            testDownMbps: completedRecord?.downMbps ?? viewModel.activeSpeedTestRecord?.downMbps,
            testUpMbps: completedRecord?.upMbps ?? viewModel.activeSpeedTestRecord?.upMbps,
            activeRecord: viewModel.activeSpeedTestRecord
        )
        inspectedHistoryID = nil
        viewModel.clearActiveSpeedTestRecord()
        resetCurrentRun()
        isRunning = true
        phase = .ping
        progress = SpeedTestProgress(phase: .ping, detail: "Preparing test")
        viewModel.setSpeedTestRunning(true)

        let runID = UUID()
        activeRunID = runID
        let engineTask = Task.detached(priority: .userInitiated) {
            try await SpeedTestEngine.runBenchmark(gatewayURL: gatewayURL) { [weak self] update in
                await MainActor.run {
                    self?.receive(update, runID: runID)
                }
            }
        }
        activeTask = engineTask
        completionTask = Task { [weak self] in
            do {
                let result = try await engineTask.value
                self?.complete(result, runID: runID)
            } catch is CancellationError {
                self?.finishCancelledRun(runID: runID)
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    self?.finishCancelledRun(runID: runID)
                } else {
                    self?.finishFailedRun(error, runID: runID)
                }
            }
        }
    }

    func cancelSpeedTest(message: String? = nil) {
        guard isRunning || activeTask != nil else { return }
        errorMessage = message
        activeTask?.cancel()
        completionTask?.cancel()
        restoreSnapshot()
    }

    private func receive(_ update: SpeedTestProgress, runID: UUID) {
        guard activeRunID == runID, isRunning else { return }
        phase = update.phase
        var next = update
        if update.phase != .ping,
           let elapsed = update.elapsed,
           elapsed < 0.4,
           update.fraction < 1 {
            if update.phase == .upload {
                next.testDownMbps = smoothedDownloadMbps
            }
            progress = next
            return
        }
        switch update.phase {
        case .download:
            let sample = max(0, update.liveDownKbps / 1_000)
            smoothedDownloadMbps = update.fraction >= 1
                ? sample
                : (smoothedDownloadMbps == 0 ? sample : smoothedDownloadMbps * 0.72 + sample * 0.28)
            speedScaleMax = max(speedScaleMax, smoothedDownloadMbps)
            next.liveDownKbps = smoothedDownloadMbps * 1_000
            next.testDownMbps = smoothedDownloadMbps
            hasDownloadReading = true
        case .upload:
            let sample = max(0, update.liveUpKbps / 1_000)
            smoothedUploadMbps = update.fraction >= 1
                ? sample
                : (smoothedUploadMbps == 0 ? sample : smoothedUploadMbps * 0.72 + sample * 0.28)
            speedScaleMax = max(speedScaleMax, smoothedUploadMbps)
            next.liveDownKbps = 0
            next.liveUpKbps = smoothedUploadMbps * 1_000
            next.testDownMbps = smoothedDownloadMbps
            next.testUpMbps = smoothedUploadMbps
            hasUploadReading = true
        case .ping:
            break
        case .idle:
            return
        }
        if let pingMs = update.pingMs { measuredPingMs = pingMs }
        if let jitterMs = update.jitterMs { measuredJitterMs = jitterMs }
        progress = next
    }

    private func complete(_ result: SpeedTestResult, runID: UUID) {
        guard activeRunID == runID else { return }
        measuredPingMs = result.pingMs
        measuredJitterMs = result.jitterMs
        smoothedDownloadMbps = result.downloadMbps
        smoothedUploadMbps = result.uploadMbps
        speedScaleMax = max(speedScaleMax, max(result.downloadMbps, result.uploadMbps))
        hasDownloadReading = true
        hasUploadReading = true
        let record = viewModel.completeSpeedTest(result)
        completedRecord = record
        hasCompletedRun = true
        progress = SpeedTestProgress(
            phase: .idle,
            fraction: 1,
            detail: "Benchmark complete",
            pingMs: result.pingMs,
            jitterMs: result.jitterMs,
            testDownMbps: result.downloadMbps,
            testUpMbps: result.uploadMbps
        )
        phase = .idle
        isRunning = false
        viewModel.setSpeedTestRunning(false)
        clearTaskReferences()
        metricsSnapshot = nil
    }

    private func finishCancelledRun(runID: UUID) {
        guard activeRunID == runID else { return }
        restoreSnapshot()
    }

    private func finishFailedRun(_ error: Error, runID: UUID) {
        guard activeRunID == runID else { return }
        errorMessage = error.localizedDescription
        restoreSnapshot()
    }

    private func restoreSnapshot() {
        let snapshot = metricsSnapshot
        measuredPingMs = snapshot?.pingMs
        measuredJitterMs = snapshot?.jitterMs
        completedRecord = snapshot?.activeRecord
        hasCompletedRun = snapshot?.activeRecord != nil
        progress = SpeedTestProgress(
            phase: .idle,
            detail: "Ready",
            pingMs: snapshot?.pingMs,
            jitterMs: snapshot?.jitterMs,
            testDownMbps: snapshot?.testDownMbps,
            testUpMbps: snapshot?.testUpMbps
        )
        phase = .idle
        isRunning = false
        viewModel.setSpeedTestRunning(false)
        viewModel.restoreActiveSpeedTestRecord(snapshot?.activeRecord)
        metricsSnapshot = nil
        activeRunID = nil
        clearTaskReferences()
    }

    private func resetCurrentRun() {
        errorMessage = nil
        completedRecord = nil
        hasCompletedRun = false
        measuredPingMs = nil
        measuredJitterMs = nil
        hasDownloadReading = false
        hasUploadReading = false
        smoothedDownloadMbps = 0
        smoothedUploadMbps = 0
        speedScaleMax = 120
    }

    private func clearTaskReferences() {
        activeTask = nil
        completionTask = nil
        activeRunID = nil
    }
}
