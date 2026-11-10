"""The floating black cat. Click through the empty pixels. Drag the cat itself."""

import sys
import time

import objc
import rumps
from AppKit import (
    NSBackingStoreBuffered,
    NSBezierPath,
    NSColor,
    NSCompositingOperationSourceOver,
    NSEvent,
    NSFloatingWindowLevel,
    NSFont,
    NSFontAttributeName,
    NSForegroundColorAttributeName,
    NSGraphicsContext,
    NSImage,
    NSImageInterpolationNone,
    NSPanel,
    NSScreen,
    NSTrackingActiveAlways,
    NSTrackingInVisibleRect,
    NSTrackingMouseEnteredAndExited,
    NSTrackingArea,
    NSTrackingMouseMoved,
    NSView,
    NSWindowCollectionBehaviorCanJoinAllSpaces,
    NSWindowCollectionBehaviorFullScreenAuxiliary,
    NSWindowCollectionBehaviorIgnoresCycle,
    NSWindowCollectionBehaviorStationary,
    NSWindowStyleMaskBorderless,
    NSWindowStyleMaskNonactivatingPanel,
)
from Foundation import NSAffineTransform, NSMakeRect, NSString

from pet_activity import Senses
from pet_logic import DRAGGING, PetMind
from pet_sprites import CAT_H, CAT_W, FRAME_COUNTS, WINDOW_H, WINDOW_W, frame_path


def _load_frames():
    images = {}
    reps = {}
    for name, count in FRAME_COUNTS.items():
        images[name] = []
        reps[name] = []
        for index in range(count):
            image = NSImage.alloc().initWithContentsOfFile_(str(frame_path(name, index)))
            if image is None:
                raise OSError(f"missing cat frame {name} {index}")
            rep = image.representations()[0]
            image.setSize_((rep.pixelsWide(), rep.pixelsHigh()))
            images[name].append(image)
            reps[name].append(rep)
    return images, reps


class CatView(NSView):
    def isOpaque(self):
        return False

    def acceptsFirstMouse_(self, event):
        return True

    def updateTrackingAreas(self):
        objc.super(CatView, self).updateTrackingAreas()
        for area in list(self.trackingAreas()):
            self.removeTrackingArea_(area)
        options = (
            NSTrackingMouseEnteredAndExited
            | NSTrackingMouseMoved
            | NSTrackingActiveAlways
            | NSTrackingInVisibleRect
        )
        tracker = NSTrackingArea.alloc().initWithRect_options_owner_userInfo_(
            self.bounds(), options, self, None
        )
        self.addTrackingArea_(tracker)
        self._tracker = tracker

    def _cat_rect(self):
        return NSMakeRect((self.bounds().size.width - CAT_W) / 2.0, 0, CAT_W, CAT_H)

    def _image_pixel(self, local):
        mind = self.mind
        name, index, facing = mind.animation(time.time())
        rep = self.reps[name][index]
        rect = self._cat_rect()
        local_x = local.x - rect.origin.x
        local_y = local.y - rect.origin.y
        if local_x < 0 or local_y < 0 or local_x >= rect.size.width or local_y >= rect.size.height:
            return None
        px = int(local_x * rep.pixelsWide() / rect.size.width)
        py = int(rep.pixelsHigh() - 1 - local_y * rep.pixelsHigh() / rect.size.height)
        if facing < 0:
            px = rep.pixelsWide() - 1 - px
        px = max(0, min(rep.pixelsWide() - 1, px))
        py = max(0, min(rep.pixelsHigh() - 1, py))
        return rep, px, py

    def solid_pixel(self, local):
        sample = self._image_pixel(local)
        if sample is None:
            return False
        rep, px, py = sample
        color = rep.colorAtX_y_(px, py)
        return color is not None and color.alphaComponent() > 0.2

    def hitTest_(self, point):
        local = self.convertPoint_fromView_(point, None)
        if self.solid_pixel(local):
            return self
        return None

    def mouseDown_(self, event):
        loc = NSEvent.mouseLocation()
        self.mind.pointer_down(time.time(), loc.x, loc.y)

    def mouseDragged_(self, event):
        loc = NSEvent.mouseLocation()
        self.mind.pointer_drag(time.time(), loc.x, loc.y)

    def mouseUp_(self, event):
        result = self.mind.pointer_up(time.time())
        if result == "moved" and self.on_move:
            self.on_move(self.mind.x, self.mind.y)
        self.setNeedsDisplay_(True)

    def mouseEntered_(self, event):
        self.mind.hover(True, time.time())

    def mouseExited_(self, event):
        self.mind.hover(False, time.time())

    def drawRect_(self, rect):
        mind = self.mind
        name, index, facing = mind.animation(time.time())
        image = self.images[name][index]
        bounds = self.bounds()
        if mind.bubble:
            self._draw_bubble(mind.bubble, bounds)
        context = NSGraphicsContext.currentContext()
        context.saveGraphicsState()
        context.setImageInterpolation_(NSImageInterpolationNone)
        width = bounds.size.width
        transform = NSAffineTransform.transform()
        transform.translateXBy_yBy_(width / 2.0, CAT_H / 2.0 + mind.breath + mind.bob)
        transform.rotateByDegrees_(mind.tilt)
        transform.scaleXBy_yBy_(-mind.stretch if facing < 0 else mind.stretch, 1.0)
        transform.concat()
        image.drawInRect_fromRect_operation_fraction_(
            NSMakeRect(-CAT_W / 2.0, -CAT_H / 2.0, CAT_W, CAT_H),
            NSMakeRect(0, 0, 0, 0),
            NSCompositingOperationSourceOver,
            1.0,
        )
        context.restoreGraphicsState()

    def _draw_bubble(self, text, bounds):
        paragraph = NSString.stringWithString_(text)
        font = NSFont.systemFontOfSize_(12)
        attrs = {
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: NSColor.whiteColor(),
        }
        size = paragraph.sizeWithAttributes_(attrs)
        bubble_w = min(bounds.size.width - 16, max(72, size.width + 16))
        bubble_h = min(52, max(22, size.height + 10))
        bubble = NSMakeRect((bounds.size.width - bubble_w) / 2.0, bounds.size.height - bubble_h - 6,
                            bubble_w, bubble_h)
        path = NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(bubble, 8, 8)
        NSColor.colorWithCalibratedWhite_alpha_(0.1, 0.9).set()
        path.fill()
        text_rect = NSMakeRect(bubble.origin.x + 8, bubble.origin.y + 4,
                               bubble.size.width - 16, bubble.size.height - 8)
        paragraph.drawInRect_withAttributes_(text_rect, attrs)


class DesktopPet:
    def __init__(self, on_move=None, senses=None):
        self.on_move = on_move
        self.mind = PetMind(time.time(), window_size=(WINDOW_W, WINDOW_H))
        self.senses = senses or Senses()
        self.window = None
        self.view = None
        self.timer = None
        self._last = time.time()
        self._told_permission = False
        self._images = None
        self._reps = None

    def show(self, origin=None):
        if self.window is None:
            self._build()
        if origin and len(origin) == 2:
            self.mind.place(origin[0], origin[1])
        else:
            self._place_default()
        self.window.setFrameOrigin_((self.mind.x, self.mind.y))
        self.window.orderFrontRegardless()
        self.senses.start()
        if self.timer is None or not self.timer.is_alive():
            self._last = time.time()
            self.timer = rumps.Timer(self._tick, 1 / 12)
            self.timer.start()

    def hide(self):
        if self.timer is not None and self.timer.is_alive():
            self.timer.stop()
        self.timer = None
        self.senses.stop()
        if self.window is not None:
            self.window.orderOut_(None)

    def set_senses(self, typing, deleting, media):
        self.senses.typing_enabled = typing
        self.senses.deleting_enabled = deleting
        self.senses.media_enabled = media
        if self.window is not None and self.window.isVisible():
            if typing or deleting:
                self.senses._start_tap()
            else:
                self.senses._stop_tap()

    def note_session(self, active):
        self.mind.note_session(bool(active), time.time())

    def _build(self):
        self._images, self._reps = _load_frames()
        rect = NSMakeRect(0, 0, WINDOW_W, WINDOW_H)
        style = NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        panel = NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
            rect, style, NSBackingStoreBuffered, False
        )
        panel.setOpaque_(False)
        panel.setBackgroundColor_(NSColor.clearColor())
        panel.setLevel_(NSFloatingWindowLevel)
        panel.setHasShadow_(False)
        panel.setFloatingPanel_(True)
        panel.setHidesOnDeactivate_(False)
        panel.setBecomesKeyOnlyIfNeeded_(True)
        panel.setMovableByWindowBackground_(False)
        panel.setCollectionBehavior_(
            NSWindowCollectionBehaviorCanJoinAllSpaces
            | NSWindowCollectionBehaviorStationary
            | NSWindowCollectionBehaviorFullScreenAuxiliary
            | NSWindowCollectionBehaviorIgnoresCycle
        )
        view = CatView.alloc().initWithFrame_(rect)
        view.mind = self.mind
        view.images = self._images
        view.reps = self._reps
        view.on_move = self.on_move
        panel.setContentView_(view)
        view.updateTrackingAreas()
        self.window = panel
        self.view = view

    def _place_default(self):
        screen = NSScreen.mainScreen()
        visible = screen.visibleFrame()
        x = visible.origin.x + visible.size.width - WINDOW_W - 36
        y = visible.origin.y + 24
        self.mind.place(x, y)

    def _bounds(self):
        screen = None
        if self.window is not None:
            screen = self.window.screen()
        screen = screen or NSScreen.mainScreen()
        visible = screen.visibleFrame()
        return (
            visible.origin.x,
            visible.origin.y,
            visible.origin.x + visible.size.width - WINDOW_W,
            visible.origin.y + visible.size.height - WINDOW_H,
        )

    def _tick(self, _timer):
        if self.window is None or not self.window.isVisible():
            return
        try:
            self._frame()
        except Exception as exc:
            print(f"desktop pet: {exc}", file=sys.stderr)

    def _frame(self):
        now = time.time()
        dt = now - self._last
        self._last = now
        activity = self.senses.snapshot(now)
        if self.senses.keyboard_ready is False and not self._told_permission and (
            self.senses.typing_enabled or self.senses.deleting_enabled
        ):
            self.mind._say(now, "Typing reactions need Accessibility. Nothing you type is saved.")
            self._told_permission = True
        mouse = NSEvent.mouseLocation()
        self.mind.tick(now, dt, self._bounds(), (mouse.x, mouse.y), activity)
        self.window.setFrameOrigin_((self.mind.x, self.mind.y))
        self.view.setNeedsDisplay_(True)
