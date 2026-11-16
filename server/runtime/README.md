# WeekGlass sync API

FastAPI and PostgreSQL implement account authorization, device management, atomic sync batches, incremental change feeds, cloud data export and entitlement checks.

See [self-hosting](../README.md) for container configuration. The server applies versioned schema changes against the configured database. To initialize the schema or provision an account manually, run these commands in the configured API container:

```sh
python -m weekglass_server.admin init-db
python -m weekglass_server.admin create-account example-user
```

For tests, install `requirements-test.txt` and run `python -m pytest tests` from this directory. Tests that exercise the database require a dedicated disposable PostgreSQL database whose name ends in `_test`. Never run the suite against a live database.

## Build the hosted API

The hosted image adds the locked Waffo SDK to the same Python API. The standard self-hosted build does not need Node, Waffo, or SMTP. The hosted build needs Docker BuildKit on Linux amd64 or a builder targeting that platform. From the repository root, prepare the locked Python wheels and Node archive, then build:

```sh
python -m pip download --require-hashes --only-binary=:all: \
  --platform manylinux_2_17_x86_64 --platform manylinux_2_28_x86_64 \
  --python-version 312 --implementation cp --abi cp312 --abi abi3 --abi none \
  -r server/runtime/requirements-linux.lock -d server/runtime/wheels
curl -fL https://nodejs.org/dist/v24.22.3/node-v24.22.3-linux-x64.tar.gz \
  -o server/runtime/node-v24.22.3-linux-x64.tar.gz
DOCKER_BUILDKIT=1 docker build --platform linux/amd64 \
  -f server/runtime/Dockerfile.hosted-waffo \
  -t weekglass-api:hosted server
```

The Dockerfile checks the Node archive against the pinned release digest and installs the SDK from its lockfile. No configuration, credentials, database data, or build downloads belong in the source checkout's commits.

### Configure the hosted service

Use the database, persistent server identity, trusted HTTPS proxy, and API container configuration in the [server guide](../README.md). Set `WEEKGLASS_MODE=hosted` to enable the hosted account console. Route both `/account` and `/account/…` to the API on the same HTTPS origin, as shown in the [WeekGlass edge configuration](../../infra/weekglass/nginx.tls.conf). This console uses browser sessions; the app keeps using the native bearer-token API.

The console provides subscription purchase, orders, device and account security, and calendar export. Hosted upload, download and merge require an active entitlement. After a subscription expires, the export workflow can deliver one calendar file for that end of service; an interrupted download can retry the same export. Self-hosted sync does not depend on an official subscription.

Waffo Live additionally requires the official `https://cloud.viliana.cn` origin. Setting Waffo variables on an independently hosted instance does not enable official payment intake.

The [Waffo overlay](../../infra/weekglass/compose.waffo-live.json) expects a base Compose file with an `api` service on a private network named `service`. It adds API egress for Waffo and SMTP without publishing another port. Keep deployment settings and secrets outside the source checkout. In the deployment directory:

- Set `WEEKGLASS_WAFFO_LIVE_IMAGE` to the image built above. Use provider-issued `WEEKGLASS_WAFFO_LIVE_MERCHANT_ID`, `WEEKGLASS_WAFFO_LIVE_STORE_ID` and `WEEKGLASS_WAFFO_LIVE_PRODUCT_ID`. For the annual plan also set `WEEKGLASS_WAFFO_LIVE_ANNUAL_PRODUCT_ID`.
- Mount the Waffo key at `secrets/waffo-live-private.pem` with access limited to the container's UID 10001 and authorized administrators. On the official host, preserve `WEEKGLASS_WAFFO_LIVE_ACCEPT_EVENTS=true` for signed payment and refund notifications. `WEEKGLASS_WAFFO_LIVE_ENABLED` controls new purchases; `WEEKGLASS_WAFFO_LIVE_ANNUAL_ENABLED` controls new annual purchases. Neither purchase switch disables settlement of orders already placed.
- With the [SMTP overlay](../../infra/weekglass/compose.smtp.json), set `WEEKGLASS_SMTP_HOST` and `WEEKGLASS_SMTP_USER` to the transactional SMTP service and sender login. The default is implicit TLS on 465. For STARTTLS, set `WEEKGLASS_SMTP_TLS=starttls` and the provider's port (usually 587). If the From address differs from the login, set `WEEKGLASS_SMTP_FROM`. Put the SMTP password in the separate `secrets/weekglass_smtp_password` file with mode `0400` and owner UID 10001; never put it in an environment file.
- Set `WEEKGLASS_EMAIL_SIGNUP_ENABLED=true` to accept new email-password registrations in hosted mode when registration is enabled. Registration sends no email. Verification and email-code recovery require a qualifying confirmed payment; they do not determine access to purchased sync.

Run from the deployment directory, where `compose.yml` is the base file and `SOURCE` is the absolute path to the source checkout:

```sh
live() {
  docker compose --env-file .env -f compose.yml \
    -f "$SOURCE/infra/weekglass/compose.waffo-live.json" \
    -f "$SOURCE/infra/weekglass/compose.smtp.json" "$@"
}
live config --quiet
live run --no-deps --rm -T api python -c \
  'from weekglass_server.email_delivery import check_connection; check_connection()'
live up -d --no-deps --wait --wait-timeout 90 api
```

The SMTP check uses TLS and authenticates without sending a message. Before enabling new purchases, inspect the Live catalog with `WaffoLive.load()` and `catalog_amount()` (100 fen monthly, 999 fen annually); this creates no orders. After switching, verify `/healthz`, `/v1/server-info`, existing account login, and the intended checkout and email routes. If mail is unavailable after email registration has opened, keep the new image and Waffo overlay, remove only the SMTP overlay, and replace only `api`. Existing logins, email-password registration, and purchased sync continue to work. Do not switch to an image that cannot sign in users who have registered with email.

### Run scoped account tests

Use a disposable PostgreSQL database for server integration tests. Set `DB_NAME` to a name ending in `_test`, configure `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD_FILE`, and provide a test server UUID and signing key file as in the server guide. Leave `DATABASE_URL` unset. Install `requirements-test.txt`, then run from `server/runtime`:

```sh
python -m pytest tests/test_console.py tests/test_email_delivery.py tests/test_email_identity.py tests/test_waffo_runtime.py
```

The browser fixture tests also require Playwright and Chromium. From a disposable test workspace with Playwright resolvable by Node, run `node --test tests/auth_email_browser.test.cjs tests/checkout_email_browser.test.cjs` from `server/runtime`. The fixtures render local pages and do not send mail or contact Waffo. From `apps/client`, run `flutter test test/cloud_account_test.dart test/cloud_auth_test.dart test/cloud_settings_test.dart` for the account panels and payment handoff.

### Check a deployed test instance

The HTTPS smoke tools are for instances you operate. From `server/runtime`, install the test dependencies plus `cryptography` (pinned in [update tools requirements](../update_tools/requirements.txt)).

- `python smoke_account_http.py --help` covers the synthetic registration and account lifecycle checks. An authorized SSH alias also enables a disposable sync entitlement and cleanup.
- `python smoke_csrf_http.py --help` checks isolation across two HTTPS ports on the same host. It requires an authorized SSH alias for synthetic account cleanup. Run it separately from the lifecycle check so both stay within server rate limits.
- `python smoke_http.py --help` checks update metadata and sync for a dedicated synthetic account. Pass the build number you intend to test and keep its credential files outside the checkout.
