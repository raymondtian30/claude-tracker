"""macOS notifications through UNUserNotificationCenter.

The older NSUserNotificationCenter (what rumps.notification uses) drops
notifications without an error on recent macOS, so alerts never showed.
UNUserNotificationCenter needs the process to be a real app bundle, which
is why build_app.py runs Python from inside "Claude Tracker.app".

pyobjc's UserNotifications wrapper isn't a dependency, so the framework is
loaded directly and the block signatures it needs are declared here.
"""

import sys
import uuid

import objc
from Foundation import NSObject
from PyObjCTools import AppHelper

FRAMEWORK = "/System/Library/Frameworks/UserNotifications.framework"
OPTION_SOUND = 1 << 1
OPTION_ALERT = 1 << 2
PRESENT_SOUND = 1 << 1
PRESENT_LIST = 1 << 3
PRESENT_BANNER = 1 << 4
STATUS_NOT_DETERMINED = 0  # UNAuthorizationStatus
STATUS_DENIED = 1
ALERT_STYLE_NONE = 0  # UNAlertStyle: only Notification Center, nothing pops up
ALERT_STYLE_BANNER = 1
BUNDLE_ID = "com.raymondtian.claudetracker"  # build_app.BUNDLE_ID (not imported: AppKit)
# Claude Tracker's own page in System Settings > Notifications.
SETTINGS_URL = f"x-apple.systempreferences:com.apple.Notifications-Settings.extension?id={BUNDLE_ID}"

_BOOL_ERROR_BLOCK = {"callable": {"retval": {"type": b"v"},
                                  "arguments": {0: {"type": b"^v"}, 1: {"type": b"Z"},
                                                2: {"type": b"@"}}}}
_ERROR_BLOCK = {"callable": {"retval": {"type": b"v"},
                             "arguments": {0: {"type": b"^v"}, 1: {"type": b"@"}}}}
_OBJECT_BLOCK = _ERROR_BLOCK
_OPTIONS_BLOCK = {"callable": {"retval": {"type": b"v"},
                               "arguments": {0: {"type": b"^v"}, 1: {"type": b"Q"}}}}

objc.registerMetaDataForSelector(
    b"UNUserNotificationCenter", b"requestAuthorizationWithOptions:completionHandler:",
    {"arguments": {3: _BOOL_ERROR_BLOCK}})
objc.registerMetaDataForSelector(
    b"UNUserNotificationCenter", b"addNotificationRequest:withCompletionHandler:",
    {"arguments": {3: _ERROR_BLOCK}})
objc.registerMetaDataForSelector(
    b"UNUserNotificationCenter", b"getNotificationSettingsWithCompletionHandler:",
    {"arguments": {2: _OBJECT_BLOCK}})
objc.registerMetaDataForSelector(
    b"NSObject", b"userNotificationCenter:willPresentNotification:withCompletionHandler:",
    {"arguments": {4: _OPTIONS_BLOCK}})

_framework = {}


def _load():
    if not _framework:
        objc.loadBundle("UserNotifications", _framework, bundle_path=FRAMEWORK)
    return _framework


class _Delegate(NSObject):
    def userNotificationCenter_willPresentNotification_withCompletionHandler_(
            self, center, notification, handler):
        # Show alerts even while the panel is open (the app is active then).
        handler(PRESENT_BANNER | PRESENT_LIST | PRESENT_SOUND)


def _log(text):
    print(f"notifications: {text}", file=sys.stderr, flush=True)  # goes to agent.err.log


class Notifier:
    """Sends notifications. `fallback(title, message)` is used where
    UNUserNotificationCenter isn't available (not running from the app
    bundle).

    Permission is looked up from macOS each time it matters, never kept:
    the user can turn notifications on or off in System Settings at any
    moment."""

    def __init__(self, title, fallback):
        self.title = title
        self.fallback = fallback
        self.center = None
        try:
            self.center = _load()["UNUserNotificationCenter"].currentNotificationCenter()
        except Exception:  # noqa: BLE001 -- not an app bundle: raises an ObjC exception
            return
        self._delegate = _Delegate.alloc().init()
        self.center.setDelegate_(self._delegate)

    def request_permission(self, then=None):
        """Asks macOS's question once (it remembers the answer), then calls
        `then(granted)` on the main thread."""
        if self.center is None:
            return

        def answered(granted, error):
            if error is not None:
                _log(f"permission request failed: {error}")
            if then:
                AppHelper.callAfter(then, bool(granted))

        self.center.requestAuthorizationWithOptions_completionHandler_(
            OPTION_ALERT | OPTION_SOUND, answered)

    def send_checked(self, message, on_blocked, on_no_banners=None):
        """Send `message` if macOS allows it right now; otherwise call
        `on_blocked()` on the main thread. If it's sent but the alert style
        is None (it only goes to Notification Center), `on_no_banners()` is
        called too. For the test alert, where the user should hear why
        nothing popped up."""
        if self.center is None:
            self.fallback(self.title, message)
            return

        def blocked():
            AppHelper.callAfter(on_blocked)

        def got_settings(settings):
            status = settings.authorizationStatus()
            if status == STATUS_DENIED:
                blocked()
            elif status == STATUS_NOT_DETERMINED:
                self.request_permission(
                    then=lambda granted: self.send(message, on_error=blocked)
                    if granted else on_blocked())
            else:
                self.send(message, on_error=blocked)
                if on_no_banners and settings.alertStyle() == ALERT_STYLE_NONE:
                    AppHelper.callAfter(on_no_banners)

        self.center.getNotificationSettingsWithCompletionHandler_(got_settings)

    def send(self, message, on_error=None):
        if self.center is None:
            self.fallback(self.title, message)
            return
        framework = _load()
        content = framework["UNMutableNotificationContent"].alloc().init()
        content.setTitle_(self.title)
        content.setBody_(message)
        content.setSound_(framework["UNNotificationSound"].defaultSound())
        request = framework["UNNotificationRequest"].requestWithIdentifier_content_trigger_(
            str(uuid.uuid4()), content, None)

        def added(error):
            if error is not None:
                _log(f"couldn't post a notification: {error}")
                if on_error:
                    on_error()

        self.center.addNotificationRequest_withCompletionHandler_(request, added)
