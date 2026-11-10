import AppKit
import TrackerCore

// The panel grows out of the menu bar icon when it opens and shrinks back into
// it when it closes, by resizing the popover and scaling its contents once per
// screen refresh.

extension PanelController {
    func animate(unfolding: Bool) {
        let from = lastShare
        stopAnimation()
        animation = (ProcessInfo.processInfo.systemUptime, unfolding, from)
        stage.isAnimating = true
        if #available(macOS 14, *) {
            // One step per screen refresh, in step with it (120 Hz on
            // ProMotion screens). A 60 Hz timer drifts against the refresh,
            // so some frames were shown twice: a stutter.
            let link = root.displayLink(target: self, selector: #selector(animationStep))
            // Common modes keep it running while a control is being clicked.
            link.add(to: .current, forMode: .common)
            animationTimer = link
        } else {
            let timer = Timer(timeInterval: 1 / PanelLayout.animationFPS, target: self,
                              selector: #selector(animationStep), userInfo: nil, repeats: true)
            RunLoop.current.add(timer, forMode: .common)
            animationTimer = timer
        }
    }

    @objc func animationStep() {
        guard let animation = animation else { return }
        // Animation turned Off mid-way (from Settings, while open): jump to
        // the end, or the step would never finish and the link would run on.
        let progress = animationSeconds > 0
            ? (ProcessInfo.processInfo.systemUptime - animation.start) / animationSeconds
            : 1
        // Each step uses the current full size, which can change if the
        // panel is redrawn mid-animation.
        let frame = PanelLayout.foldFrame(progress: progress, unfolding: animation.unfolding,
                                          fromShare: animation.fromShare, fullSize: fullSize)
        show(frame: frame)
        lastShare = frame.share
        if progress >= 1 {
            stopAnimation()
            if animation.unfolding {
                resetToFullSize(share: 1)
            } else {
                // Close first, then reset: the other way round shows the
                // full-size panel for a frame in the small window.
                popover.close()
                resetToFullSize(share: 0)
            }
        }
    }

    func stopAnimation() {
        if #available(macOS 14, *), let link = animationTimer as? CADisplayLink {
            link.invalidate()
        }
        (animationTimer as? Timer)?.invalidate()
        animationTimer = nil
        animation = nil
    }
}
