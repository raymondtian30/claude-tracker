import notifications
from notifications import STATUS_DENIED, STATUS_NOT_DETERMINED, Notifier

AUTHORIZED = 2


class FakeSettings:
    def __init__(self, status):
        self.status = status

    def authorizationStatus(self):
        return self.status


class FakeCenter:
    """Answers like UNUserNotificationCenter, straight away."""

    def __init__(self, status, grant=True, post_error=None):
        self.status, self.grant, self.post_error = status, grant, post_error
        self.posted = []

    def getNotificationSettingsWithCompletionHandler_(self, handler):
        handler(FakeSettings(self.status))

    def requestAuthorizationWithOptions_completionHandler_(self, options, handler):
        self.status = AUTHORIZED if self.grant else STATUS_DENIED
        handler(self.grant, None)

    def addNotificationRequest_withCompletionHandler_(self, request, handler):
        self.posted.append(request.content().body())
        handler(self.post_error)


def notifier(center, monkeypatch):
    monkeypatch.setattr(notifications.AppHelper, "callAfter", lambda f, *args: f(*args))
    n = Notifier.__new__(Notifier)
    n.title, n.fallback, n.center = "Claude Tracker", None, center
    return n


def test_test_alert_is_sent_once_allowed_in_system_settings(monkeypatch):
    """Turning notifications on in System Settings works straight away: the
    permission is looked up on each test alert, not remembered."""
    center = FakeCenter(STATUS_DENIED)
    n = notifier(center, monkeypatch)
    blocked = []

    n.send_checked("hi", on_blocked=lambda: blocked.append(1))
    center.status = AUTHORIZED  # the user allows it in System Settings
    n.send_checked("hi again", on_blocked=lambda: blocked.append(1))

    assert blocked == [1]
    assert center.posted == ["hi again"]


def test_test_alert_asks_when_macos_hasnt_asked_yet(monkeypatch):
    center = FakeCenter(STATUS_NOT_DETERMINED, grant=True)
    n = notifier(center, monkeypatch)

    n.send_checked("hi", on_blocked=lambda: None)

    assert center.posted == ["hi"]


def test_test_alert_says_blocked_when_permission_refused_or_posting_fails(monkeypatch):
    blocked = []
    for center in (FakeCenter(STATUS_NOT_DETERMINED, grant=False),
                   FakeCenter(AUTHORIZED, post_error="nope")):
        notifier(center, monkeypatch).send_checked("hi", on_blocked=lambda: blocked.append(1))

    assert blocked == [1, 1]
