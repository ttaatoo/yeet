//  Created by Marcin Krzyzanowski
//  https://github.com/krzyzanowskim/STTextView/blob/main/LICENSE.md

import Foundation
import AppKit
import AVFoundation

extension STTextView {

    /// Speaks the selected text, or all text if no selection.
    @objc open func startSpeaking(_ sender: Any?) {
        stopSpeaking(sender)

        let attrString: NSAttributedString
        let selectionTextRanges = textLayoutManager.textSelectionsRanges(.withoutInsertionPoints)
        if selectionTextRanges.isEmpty {
            attrString = attributedString()
        } else {
            attrString = textLayoutManager.textAttributedString(in: selectionTextRanges) ?? NSAttributedString()
        }

        if !attrString.isEmpty {
            let utterance = AVSpeechUtterance(attributedString: attrString)
            utterance.prefersAssistiveTechnologySettings = true
            _speechSynthesizerIsSpeaking = true
            _speechSynthesizer.speak(utterance)
        } else {
            _speechSynthesizerIsSpeaking = false
        }
    }

    /// Stops the speaking of text.
    @objc open func stopSpeaking(_ sender: Any?) {
        if _speechSynthesizerIsSpeaking {
            _speechSynthesizer.stopSpeaking(at: .word)
        }
    }
}

extension STTextView: AVSpeechSynthesizerDelegate {

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?._speechSynthesizerIsSpeaking = true
        }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?._speechSynthesizerIsSpeaking = false
        }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?._speechSynthesizerIsSpeaking = false
        }
    }
}
