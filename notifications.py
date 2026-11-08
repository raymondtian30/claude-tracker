"""macOS notifications through UNUserNotificationCenter.

The older NSUserNotificationCenter (what rumps.notification uses) drops
notifications without an error on recent macOS, so alerts never showed.
UNUserNotificationCenter needs the process to be a real app bundle, which
is why build_app.py runs Python from inside "Claude Tracker.app".

pyobjc's UserNotifications wrapper isn't a dependency, so the framework is
loaded directly and the block signatures it needs are declared here.
"""

import uuid

import objc
from Foundation import NSObject

FRAMEWORK = "/System/Library/Frameworks/UserNotifications.framework"
OPTION_SOUND = 1 << 1
OPTION_ALERT = 1 << 2
PRESENT_SOUND = 1 << 1
PRESENT_LIST = 1 << 3
PRESENT_BANNER = 1 << 4
STATUS_DENIED = 1  # UNAuthorizationStatusDenied
SETTINGS_URL = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"

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


class Notifier:
    """Sends notifications. `fallback(title, message)` is used where
    UNUserNotificationCenter isn't available (not running from the app
    bundle)."""

    def __init__(self, title, fallback):
        self.title = title
        self.fallback = fallback
        self.center = None
        self.denied = False
        try:
            self.center = _load()["UNUserNotificationCenter"].currentNotificationCenter()
        except Exception:  # noqa: BLE001 -- not an app bundle: raises an ObjC exception
            return
        self._delegate = _Delegate.alloc().init()
        self.center.setDelegate_(self._delegate)

    def request_permission(self):
        """Asks once (macOS remembers the answer)."""
        if self.center is None:
            return

        def answered(granted, error):
            self.denied = not granted

        self.center.requestAuthorizationWithOptions_completionHandler_(
            OPTION_ALERT | OPTION_SOUND, answered)

    def send(self, message):
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
                self.denied = True

        self.center.addNotificationRequest_withCompletionHandler_(request, added)
