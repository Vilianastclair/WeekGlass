"""Fill the disposable account's real form before the simulator taps Connect.

Only loaded by the loopback test server, never by the client or deployed API.
Authentication, CSRF, PKCE, the redirect, token exchange and Keychain stay live.
"""
import html
import os
from pathlib import Path
from weekglass_server import auth
from weekglass_server.main import app

password = Path(os.environ['WG_DISPOSABLE_PASSWORD_FILE']).read_text().strip()
assert os.environ['WEEKGLASS_PUBLIC_ORIGIN'] == 'https://127.0.0.1:18766'
render = auth.page


def filled_form(*args, **kwargs):
    page = render(*args, **kwargs)
    return page.replace('id="login-username" ', 'id="login-username" value="iphonefixture" ').replace(
        'id="login-password" ', 'id="login-password" value="' + html.escape(password, quote=True) + '" ')


auth.page = filled_form
