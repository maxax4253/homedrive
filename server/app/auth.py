"""Signed login tokens: username + version + expiry, signed with the server secret."""

import base64
import hashlib
import hmac
import time


def _sign(payload: str, secret: str) -> str:
    return hmac.new(secret.encode(), payload.encode(), hashlib.sha256).hexdigest()


def make_token(username: str, version: int, secret: str, days: int) -> str:
    expires = int(time.time()) + days * 86400
    payload = f"{username}:{version}:{expires}"
    return base64.urlsafe_b64encode(f"{payload}:{_sign(payload, secret)}".encode()).decode()


def check_token(token: str, secret: str) -> tuple[str, int] | None:
    """Return (username, version) if the token is genuine and not expired."""
    try:
        raw = base64.urlsafe_b64decode(token.encode()).decode()
        username, version, expires, sig = raw.rsplit(":", 3)
        version_n, expires_n = int(version), int(expires)
    except Exception:
        return None
    if not hmac.compare_digest(sig, _sign(f"{username}:{version}:{expires}", secret)):
        return None
    if expires_n < time.time():
        return None
    return username, version_n


def sign_value(value: str, secret: str, seconds: int) -> str:
    """Short-lived signed value (used for unlocking password-protected share links)."""
    expires = int(time.time()) + seconds
    return f"{expires}.{_sign(f'{value}:{expires}', secret)[:32]}"


def check_signed_value(value: str, signed: str, secret: str) -> bool:
    try:
        expires, sig = signed.split(".", 1)
        if int(expires) < time.time():
            return False
    except Exception:
        return False
    return hmac.compare_digest(sig, _sign(f"{value}:{expires}", secret)[:32])
