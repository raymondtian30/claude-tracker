import AppKit
import TrackerCore

// The panel unfolds down from the menu bar when it opens and folds back up
// when it closes, by resizing the popover once per screen refresh.

extension PanelController {
    func animate(unfolding: Bool) {
        let current = popover.contentSize.height
        stopAnimation()
        animation = (ProcessInfo.processInfo.systemUptime, unfolding, current)
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
        let height: CGFloat
        if animation.unfolding {
            // Unfold towards the current full height, which can change if
            // the panel is redrawn mid-animation.
            height = PanelLayout.foldHeight(progress, fullHeight, unfolding: true)
        } else {
            height = PanelLayout.foldHeight(progress, animation.from, unfolding: false)
        }
        popover.contentSize = NSSize(width: PanelLayout.width, height: height)
        if progress >= 1 {
            stopAnimation()
            if !animation.unfolding {
                popover.close()
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
