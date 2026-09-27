import AVFoundation
import QuartzCore
import UIKit

/// Pencil-on-paper scratch while typing in the diary.
///
/// Plays short strokes cut from a real pencil recording (Sounds/PencilScratch-*.wav),
/// picked at random with a little pitch and volume drift so no two keys sound
/// alike. The session is `.ambient`: it follows the silent switch and mixes
/// with whatever the user is listening to.
final class PencilSound {
    static let shared = PencilSound()
    static let enabledKey = "pencilSoundEnabled"

    private static let clipCount = 16

    private let engine = AVAudioEngine()
    /// A few voices in rotation so fast typing overlaps instead of cutting off.
    private var voices: [(player: AVAudioPlayerNode, pitch: AVAudioUnitVarispeed)] = []
    private var buffers: [AVAudioPCMBuffer] = []
    private var nextVoice = 0
    private var lastClip = -1
    private var isPrepared = false
    private var lastPlayTime: CFTimeInterval = 0
    private var idleStop: DispatchWorkItem?

    private init() {}

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    func play() {
        guard Self.isEnabled else { return }
        let now = CACurrentMediaTime()
        // Autorepeat and paste can fire many changes at once; one stroke is enough.
        guard now - lastPlayTime > 0.045 else { return }
        lastPlayTime = now

        prepareIfNeeded()
        guard !buffers.isEmpty else { return }
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }

        // Never the same stroke twice in a row.
        var clip = Int.random(in: 0..<buffers.count)
        if clip == lastClip, buffers.count > 1 { clip = (clip + 1) % buffers.count }
        lastClip = clip

        let voice = voices[nextVoice]
        nextVoice = (nextVoice + 1) % voices.count
        voice.pitch.rate = Float.random(in: 0.9...1.1)
        voice.player.volume = Float.random(in: 0.35...0.6)
        voice.player.scheduleBuffer(buffers[clip], at: nil, options: .interrupts)
        if !voice.player.isPlaying { voice.player.play() }

        scheduleIdleStop()
    }

    private func prepareIfNeeded() {
        guard !isPrepared else { return }
        isPrepared = true

        buffers = (1...Self.clipCount).compactMap { index in
            let name = String(format: "PencilScratch-%02d", index)
            guard let url = Bundle.main.url(forResource: name, withExtension: "wav"),
                  let file = try? AVAudioFile(forReading: url),
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                  (try? file.read(into: buffer)) != nil else { return nil }
            return buffer
        }
        guard let format = buffers.first?.format else { return }

        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)

        for _ in 0..<3 {
            let player = AVAudioPlayerNode()
            let pitch = AVAudioUnitVarispeed()
            engine.attach(player)
            engine.attach(pitch)
            engine.connect(player, to: pitch, format: format)
            engine.connect(pitch, to: engine.mainMixerNode, format: format)
            voices.append((player, pitch))
        }
        engine.mainMixerNode.outputVolume = 0.5
    }

    /// A running engine keeps the audio hardware awake, so stop it once typing pauses.
    private func scheduleIdleStop() {
        idleStop?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.voices.forEach { $0.player.stop() }
            self.engine.stop()
        }
        idleStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
}

// MARK: - Pencil on the caret

/// A small pencil that rests its tip on the caret while typing, nudges with
/// each keystroke and fades out once typing pauses.
final class PencilCaret {
    private let imageView = UIImageView()
    private var hideWork: DispatchWorkItem?

    init() {
        imageView.isUserInteractionEnabled = false
        imageView.alpha = 0
        imageView.contentMode = .scaleAspectFit
    }

    func textDidChange(in textView: UITextView) {
        // Wait a tick so the caret reflects the new layout.
        DispatchQueue.main.async { [weak self, weak textView] in
            guard let self, let textView, textView.isFirstResponder else { return }
            self.show(in: textView)
        }
    }

    func hide() {
        hideWork?.cancel()
        UIView.animate(withDuration: 0.25) { self.imageView.alpha = 0 }
    }

    private func show(in textView: UITextView) {
        guard let range = textView.selectedTextRange else { return }
        let caret = textView.caretRect(for: range.end)
        guard !caret.isNull, !caret.isInfinite, caret.height > 0 else { return }

        if imageView.superview !== textView {
            textView.addSubview(imageView)
            // Scrolling is off, so letting the pencil poke above the first line is safe.
            textView.clipsToBounds = false
        }

        let side = max(16, caret.height * 0.9)
        if imageView.image == nil {
            imageView.image = UIImage(named: "PencilCaret")
        }

        // The image is cropped so the tip sits at its bottom-left corner: put it on the bottom of the caret.
        imageView.transform = .identity
        imageView.frame = CGRect(x: caret.maxX, y: caret.maxY - side, width: side, height: side)

        imageView.transform = CGAffineTransform(rotationAngle: CGFloat.random(in: -0.12 ... -0.05))
        UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.imageView.transform = .identity
            self.imageView.alpha = 1
        }

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}
