//
//  GlobalHotKeySettingsView.swift
//  kero
//

import AppKit
import SwiftUI

/// AppKit-owned global hotkey recorder row for the legacy SwiftUI Settings mount point.
///
/// Recording installs a *local* key-down monitor (this process only). That
/// monitor must be removed when Settings closes or the row is dismantled —
/// otherwise it swallows every key in terminals and the editor.
@MainActor
final class GlobalHotKeySettingsView: NSView {
    private let titleLabel = NSTextField(
        labelWithString: String(localized: "Global hotkey")
    )
    private let descriptionLabel = NSTextField(
        wrappingLabelWithString: String(
            localized: "Summons or hides Yeet from any app. Click to record a new shortcut. Default ⌥Space is also Raycast's default.",
            comment: "Explanation of what the global hotkey does."
        )
    )
    private let recorderButton = NSButton(
        title: "",
        target: nil,
        action: nil
    )
    private let clearButton = NSButton(
        image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)!,
        target: nil,
        action: nil
    )
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let textStack = NSStackView()

    private var isRecording = false
    private var eventMonitor: Any?
    private var windowObservers: [NSObjectProtocol] = []
    private var registrationFailed = false

    var changeHandler: ((KeyCombo?) -> Void)?
    private var appliedKeyCombo: KeyCombo?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        descriptionLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.maximumNumberOfLines = 0
        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 0
        errorLabel.isHidden = true

        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.detachesHiddenViews = true
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(descriptionLabel)
        textStack.addArrangedSubview(errorLabel)
        textStack.setCustomSpacing(5, after: descriptionLabel)

        recorderButton.bezelStyle = .roundRect
        recorderButton.target = self
        recorderButton.action = #selector(startRecording)
        recorderButton.refusesFirstResponder = true
        recorderButton.setAccessibilityLabel(String(localized: "Global hotkey"))

        clearButton.bezelStyle = .inline
        clearButton.isBordered = false
        clearButton.imageScaling = .scaleProportionallyDown
        clearButton.target = self
        clearButton.action = #selector(clearHotkey)
        clearButton.refusesFirstResponder = true
        clearButton.setAccessibilityLabel(String(localized: "Clear global hotkey"))
        clearButton.contentTintColor = .secondaryLabelColor

        let buttonStack = NSStackView(views: [recorderButton, clearButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 4
        buttonStack.alignment = .centerY

        textStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        recorderButton.setContentHuggingPriority(.required, for: .horizontal)
        clearButton.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(textStack)
        addSubview(buttonStack)

        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            textStack.topAnchor.constraint(equalTo: topAnchor),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            textStack.trailingAnchor.constraint(
                lessThanOrEqualTo: buttonStack.leadingAnchor,
                constant: -16
            ),
            buttonStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            buttonStack.topAnchor.constraint(equalTo: topAnchor),
            recorderButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            clearButton.widthAnchor.constraint(equalToConstant: 20),
            clearButton.heightAnchor.constraint(equalToConstant: 20),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(keyCombo: KeyCombo?, registrationFailed: Bool = false) {
        appliedKeyCombo = keyCombo
        self.registrationFailed = registrationFailed
        updateButtonState()
    }

    /// Drops the local monitor even if recording state is inconsistent.
    /// Called from `dismantleNSView` and when the row leaves its window.
    func teardownRecording() {
        removeEventMonitor()
        removeWindowObservers()
        let wasRecording = isRecording
        isRecording = false
        if wasRecording {
            updateButtonState()
        }
    }

    private func updateButtonState() {
        if isRecording {
            recorderButton.title = String(
                localized: "Press keys…",
                comment: "Button state when recording a keyboard shortcut"
            )
            recorderButton.bezelColor = .controlAccentColor
            clearButton.isHidden = true
            errorLabel.isHidden = true
        } else if let combo = appliedKeyCombo {
            recorderButton.title = combo.displayString
            recorderButton.bezelColor = nil
            clearButton.isHidden = false

            if registrationFailed {
                errorLabel.stringValue = String(
                    localized: "Registration failed. Another app may be using this shortcut.",
                    comment: "Error shown when global hotkey registration fails"
                )
                errorLabel.isHidden = false
            } else {
                errorLabel.isHidden = true
            }
        } else {
            recorderButton.title = String(
                localized: "None",
                comment: "Button state when no global hotkey is set"
            )
            recorderButton.bezelColor = nil
            clearButton.isHidden = true
            errorLabel.isHidden = true
        }
        invalidateIntrinsicContentSize()
    }

    @objc private func startRecording() {
        guard !isRecording else {
            stopRecording()
            return
        }

        isRecording = true
        updateButtonState()

        // Local to this app — not a global monitor. Returning nil swallows the
        // key so it does not type into Settings or fire menu equivalents.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            assumeMainActor {
                guard let self else { return event }

                if event.keyCode == 53 { // Escape cancels without changing the binding
                    self.stopRecording()
                    return nil
                }

                if let combo = KeyCombo(event: event) {
                    // Persist first so register sees the new combo, not the old one.
                    self.appliedKeyCombo = combo
                    self.changeHandler?(combo)
                    self.registrationFailed = AppSettings.shared.globalHotkeyRegistrationFailed
                    self.stopRecording()
                    return nil
                }

                NSSound.beep()
                return nil
            }
        }

        installWindowObservers()
        window?.makeFirstResponder(self)
    }

    private func stopRecording() {
        guard isRecording else { return }
        teardownRecording()
    }

    @objc private func clearHotkey() {
        appliedKeyCombo = nil
        registrationFailed = false
        changeHandler?(nil)
        updateButtonState()
    }

    private func removeEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func installWindowObservers() {
        removeWindowObservers()
        guard let window else { return }

        // Closing Settings, clicking another window, or hiding the app must
        // not leave the swallow-all key monitor installed.
        for name in [
            NSWindow.didResignKeyNotification,
            NSApplication.didResignActiveNotification,
        ] as [NSNotification.Name] {
            windowObservers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: name == NSWindow.didResignKeyNotification ? window : nil,
                queue: .main
            ) { [weak self] _ in
                assumeMainActor {
                    self?.stopRecording()
                }
            })
        }
    }

    private func removeWindowObservers() {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()
    }

    override var acceptsFirstResponder: Bool {
        isRecording
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            teardownRecording()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            teardownRecording()
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: ceil(max(textStack.fittingSize.height, 44))
        )
    }
}

/// SwiftUI only mounts the native row inside the pre-existing Settings form.
struct GlobalHotKeySettingsRow: NSViewRepresentable {
    let keyCombo: KeyCombo?
    let registrationFailed: Bool
    let onChange: (KeyCombo?) -> Void

    func makeNSView(context: Context) -> GlobalHotKeySettingsView {
        let view = GlobalHotKeySettingsView(frame: .zero)
        view.changeHandler = onChange
        view.apply(keyCombo: keyCombo, registrationFailed: registrationFailed)
        return view
    }

    func updateNSView(_ view: GlobalHotKeySettingsView, context: Context) {
        view.changeHandler = onChange
        view.apply(keyCombo: keyCombo, registrationFailed: registrationFailed)
    }

    static func dismantleNSView(_ view: GlobalHotKeySettingsView, coordinator: ()) {
        view.teardownRecording()
    }
}
