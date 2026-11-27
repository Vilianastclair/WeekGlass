"""Submit the disposable account's real form using Safari on the simulator.

Only loaded by the loopback test server, never by the client or deployed API.
Authentication, CSRF, PKCE, the redirect, token exchange and Keychain stay live.
"""
import html
import os
from pathlib import Path
from weekglass_server import auth, auth_pages
from weekglass_server.main import app as api

password = Path(os.environ['WG_DISPOSABLE_PASSWORD_FILE']).read_text().strip()
assert os.environ['WEEKGLASS_PUBLIC_ORIGIN'] == 'https://127.0.0.1:18766'
render = auth.page


def filled_form(*args, **kwargs):
    page = render(*args, **kwargs)
    return page.replace('id="login-username" ', 'id="login-username" value="iphonefixture" ').replace(
        'id="login-password" ', 'id="login-password" value="' + html.escape(password, quote=True) + '" ')


auth.page = filled_form


# Safari's remote view does not consistently expose form controls to XCTest.
# Submit in the real browser. Keep the production post, cookie and validation.
auth_pages.FORM_SCRIPT += """
;(function(){
  const input = document.getElementById('login-username');
  if (input && !document.querySelector('[role="alert"]')) {
    setTimeout(function(){ input.form.requestSubmit(); }, 300);
  }
})();"""
auth.FORM_SCRIPT_SOURCE = auth_pages._script_source(auth_pages.FORM_SCRIPT)


async def app(scope, receive, send):
    async def record(message):
        if scope['type'] == 'http' and message['type'] == 'http.response.start':
            # Never log query strings, bodies or headers.
            print('fixture:', scope['method'], scope['path'], message['status'], flush=True)
        await send(message)
    await api(scope, receive, record)
