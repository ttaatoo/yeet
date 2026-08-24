//
//  TerminalProgress.swift
//  kero
//

import AppKit

/// OSC 9;4 progress report states.
enum TerminalProgressState {
    case remove
    case set
    case error
    case indeterminate
    case pause
}

/// Layer-backed progress indicator used for OSC 9;4 reports. It deliberately
/// ignores hit testing so terminal selection and clicks pass through it.
final class KeroTerminalProgressBarView: NSView {
    private let trackLayer = CALayer()
    private let barLayer = CALayer()
    private let indeterminateAnimationKey = "keroTerminalProgressIndeterminate"

    private var state: TerminalProgressState = .remove
    private var progress: Int?
    private var lastProgressValue: Int?
    private var reportTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        layer?.masksToBounds = true
        trackLayer.isHidden = true
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(barLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        reportTimer?.invalidate()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        updateForCurrentState(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply(state: state, progress: progress)
    }

    func applyReport(state: TerminalProgressState, percent: Int?) {
        if case .remove = state {
            clearReport()
            return
        }

        let resolved: Int?
        switch state {
        case .remove:
            resolved = nil
        case .set:
            resolved = percent ?? 0
        case .error:
            resolved = percent ?? lastProgressValue
        case .indeterminate:
            resolved = nil
        case .pause:
            resolved = percent ?? lastProgressValue ?? 100
        }
        let clamped = resolved.map { min(max($0, 0), 100) }
        if let clamped {
            lastProgressValue = clamped
        }

        let displayProgress: Int?
        if case .indeterminate = state {
            displayProgress = nil
        } else {
            displayProgress = clamped
        }
        apply(state: state, progress: displayProgress)
        reportTimer?.invalidate()
        reportTimer = Timer.scheduledTimer(
            withTimeInterval: 15, repeats: false
        ) { [weak self] _ in
            self?.clearReport()
        }
    }

    private func clearReport() {
        reportTimer?.invalidate()
        reportTimer = nil
        lastProgressValue = nil
        apply(state: .remove, progress: nil)
    }

    private func apply(state: TerminalProgressState, progress: Int?) {
        self.state = state
        self.progress = progress

        if case .remove = state {
            isHidden = true
            stopIndeterminateAnimation()
            return
        }

        isHidden = false
        let color: NSColor
        switch state {
        case .error:
            color = .systemRed
        case .pause:
            color = Theme.chromeAccent
        default:
            color = Theme.chromeProgress
        }
        barLayer.backgroundColor = color.cgColor
        trackLayer.backgroundColor = color.withAlphaComponent(0.3).cgColor
        updateForCurrentState(animated: true)
    }

    private func updateForCurrentState(animated: Bool) {
        guard !isHidden else { return }
        trackLayer.frame = bounds
        if let progress {
            updateDeterminate(progress: progress, animated: animated)
        } else {
            updateIndeterminate()
        }
    }

    private func updateDeterminate(progress: Int, animated: Bool) {
        trackLayer.isHidden = true
        stopIndeterminateAnimation()
        let width = bounds.width * CGFloat(progress) / 100
        let target = CGRect(x: 0, y: 0, width: width, height: bounds.height)

        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.2)
            CATransaction.setAnimationTimingFunction(
                CAMediaTimingFunction(name: .easeInEaseOut)
            )
        } else {
            CATransaction.setDisableActions(true)
        }
        barLayer.frame = target
        CATransaction.commit()
    }

    private func updateIndeterminate() {
        trackLayer.isHidden = false
        let width = bounds.width * 0.25
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        barLayer.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        CATransaction.commit()

        guard width > 0, bounds.width > width else {
            stopIndeterminateAnimation()
            return
        }

        stopIndeterminateAnimation()
        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = width / 2
        animation.toValue = bounds.width - width / 2
        animation.duration = 1.2
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        barLayer.add(animation, forKey: indeterminateAnimationKey)
    }

    private func stopIndeterminateAnimation() {
        barLayer.removeAnimation(forKey: indeterminateAnimationKey)
    }
}
