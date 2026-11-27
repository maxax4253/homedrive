"""Signed login tokens (no database needed)."""

import base64
import hashlib
import hmac
import time


def make_token(username: str, secret: str, days: int) -> str:
    expires = int(time.time()) + days * 86400
    payload = f"{username}:{expires}"
    sig = hmac.new(secret.encode(), payload.encode(), hashlib.sha256).hexdigest()
    return base64.urlsafe_b64encode(f"{payload}:{sig}".encode()).decode()


def check_token(token: str, secret: str) -> str | None:
    """Return the username if the token is valid, else None."""
    try:
        raw = base64.urlsafe_b64decode(token.encode()).decode()
        username, expires, sig = raw.rsplit(":", 2)
    except Exception:
        return None
    payload = f"{username}:{expires}"
    expected = hmac.new(secret.encode(), payload.encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(sig, expected):
        return None
    if int(expires) < time.time():
        return None
    return username


def check_password(given: str, expected: str) -> bool:
    return hmac.compare_digest(given.encode(), expected.encode())
