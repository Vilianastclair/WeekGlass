"""Send WeekGlass account codes through an explicitly configured SMTP service."""

import os
import smtplib
import ssl
from contextlib import contextmanager
from dataclasses import dataclass, field
from email.headerregistry import Address
from email.message import EmailMessage
from email.utils import formatdate, make_msgid
from pathlib import Path


_SUBJECTS = {
    "login": "WeekGlass 登录验证码",
    "reset": "WeekGlass 重设密码验证码",
    "bind": "WeekGlass 邮箱验证码",
    "change_old": "WeekGlass 验证原邮箱",
    "change_new": "WeekGlass 验证新邮箱",
}


class DeliveryError(Exception):
    """Delivery failed; do not return provider details to a caller."""


@dataclass(frozen=True)
class _SMTP:
    host: str
    port: int
    tls: str
    user: str
    sender: Address
    password: str = field(repr=False)


def _configuration() -> _SMTP | None:
    host = os.getenv("WEEKGLASS_SMTP_HOST", "").strip()
    user = os.getenv("WEEKGLASS_SMTP_USER", "").strip()
    from_address = os.getenv("WEEKGLASS_SMTP_FROM", "").strip() or user
    password_file = os.getenv("WEEKGLASS_SMTP_PASSWORD_FILE", "").strip()
    tls = os.getenv("WEEKGLASS_SMTP_TLS", "implicit").strip()
    if not host or not user or not password_file or tls not in ("implicit", "starttls"):
        return None
    try:
        port = int(os.getenv("WEEKGLASS_SMTP_PORT", "465" if tls == "implicit" else "587"))
        if not 1 <= port <= 65535:
            return None
        password = Path(password_file).read_text(encoding="utf-8").rstrip("\r\n")
        sender = Address(display_name="WeekGlass", addr_spec=from_address)
    except (OSError, ValueError):
        return None
    if not password or not sender.username or not sender.domain:
        return None
    return _SMTP(host, port, tls, user, sender, password)


def available() -> bool:
    return _configuration() is not None


@contextmanager
def _authenticated(config: _SMTP):
    context = ssl.create_default_context()
    if config.tls == "implicit":
        connection = smtplib.SMTP_SSL(config.host, config.port, timeout=5, context=context)
    else:
        connection = smtplib.SMTP(config.host, config.port, timeout=5)
    with connection as smtp:
        if config.tls == "starttls":
            smtp.starttls(context=context)
        smtp.login(config.user, config.password)
        yield smtp


def check_connection() -> None:
    """Check TLS and authentication without sending mail."""
    config = _configuration()
    if config is None:
        raise DeliveryError("Email delivery is not configured")
    try:
        with _authenticated(config):
            pass
    except (OSError, smtplib.SMTPException):
        raise DeliveryError("Email delivery is unavailable") from None


def send_code(email: str, purpose: str, code: str) -> None:
    subject = _SUBJECTS.get(purpose)
    if subject is None:
        raise DeliveryError("Unsupported email challenge")
    config = _configuration()
    if config is None:
        raise DeliveryError("Email delivery is not configured")
    try:
        recipient = Address(addr_spec=email)
        message = EmailMessage()
        message["From"] = config.sender
        message["To"] = recipient
        message["Subject"] = subject
        message["Date"] = formatdate(usegmt=True)
        message["Message-ID"] = make_msgid(domain=config.sender.domain)
        message.set_content(
            f"你的 WeekGlass 验证码是：{code}\n\n"
            "验证码 10 分钟内有效。请勿把验证码告诉任何人。"
            "如果不是你发起的请求，请忽略这封邮件。\n"
        )
        with _authenticated(config) as smtp:
            smtp.send_message(message)
    except (OSError, ValueError, smtplib.SMTPException):
        raise DeliveryError("Email delivery is unavailable") from None
