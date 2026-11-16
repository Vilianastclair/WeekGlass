import smtplib
import ssl
from unittest.mock import MagicMock

import pytest

from weekglass_server import email_delivery


@pytest.fixture
def smtp_settings(monkeypatch, tmp_path):
    secret = tmp_path / "smtp-password"
    secret.write_text("test-only-password\n", encoding="utf-8")
    monkeypatch.setenv("WEEKGLASS_SMTP_HOST", "smtp.example.test")
    monkeypatch.setenv("WEEKGLASS_SMTP_USER", "mailer@example.test")
    monkeypatch.setenv("WEEKGLASS_SMTP_FROM", "delivery@example.test")
    monkeypatch.setenv("WEEKGLASS_SMTP_PASSWORD_FILE", str(secret))
    monkeypatch.delenv("WEEKGLASS_SMTP_PORT", raising=False)
    monkeypatch.delenv("WEEKGLASS_SMTP_TLS", raising=False)
    return secret


def test_implicit_tls_sends_only_weekglass_code(monkeypatch, smtp_settings):
    smtp = MagicMock()
    smtp.return_value.__enter__.return_value = connection = MagicMock()
    monkeypatch.setattr(smtplib, "SMTP_SSL", smtp)
    assert email_delivery.available()
    email_delivery.send_code("reader@example.test", "bind", "482901")
    assert smtp.call_args.args == ("smtp.example.test", 465)
    context = smtp.call_args.kwargs["context"]
    assert context.check_hostname and context.verify_mode == ssl.CERT_REQUIRED
    connection.login.assert_called_once_with("mailer@example.test", "test-only-password")
    message = connection.send_message.call_args.args[0]
    assert message["From"].addresses[0].display_name == "WeekGlass"
    assert message["From"].addresses[0].addr_spec == "delivery@example.test"
    assert message["To"].addresses[0].addr_spec == "reader@example.test"
    assert message["Subject"] == "WeekGlass 邮箱验证码"
    assert "482901" in message.get_content()


def test_signup_is_not_a_delivery_purpose(monkeypatch, smtp_settings):
    smtp = MagicMock()
    monkeypatch.setattr(smtplib, "SMTP_SSL", smtp)
    with pytest.raises(email_delivery.DeliveryError, match="^Unsupported email challenge$"):
        email_delivery.send_code("reader@example.test", "register", "123456")
    smtp.assert_not_called()


def test_missing_secret_and_smtp_errors_do_not_fall_back(monkeypatch, smtp_settings):
    smtp = MagicMock(side_effect=smtplib.SMTPAuthenticationError(535, b"provider detail"))
    monkeypatch.setattr(smtplib, "SMTP_SSL", smtp)
    with pytest.raises(email_delivery.DeliveryError, match="^Email delivery is unavailable$"):
        email_delivery.send_code("reader@example.test", "login", "123456")
    smtp_settings.unlink()
    assert not email_delivery.available()
    with pytest.raises(email_delivery.DeliveryError, match="^Email delivery is not configured$"):
        email_delivery.send_code("reader@example.test", "login", "123456")
    smtp.assert_called_once()


def test_starttls_is_required_before_authentication(monkeypatch, smtp_settings):
    monkeypatch.setenv("WEEKGLASS_SMTP_TLS", "starttls")
    smtp = MagicMock()
    smtp.return_value.__enter__.return_value = connection = MagicMock()
    connection.starttls.side_effect = smtplib.SMTPNotSupportedError()
    monkeypatch.setattr(smtplib, "SMTP", smtp)
    with pytest.raises(email_delivery.DeliveryError):
        email_delivery.check_connection()
    assert smtp.call_args.args == ("smtp.example.test", 587)
    connection.login.assert_not_called()
    connection.send_message.assert_not_called()
