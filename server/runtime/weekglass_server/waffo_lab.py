"""Local entry point for signed Waffo Test calls; normal deployment never loads it."""
import argparse
from contextlib import asynccontextmanager
import secrets
from urllib.parse import urlsplit
from uuid import UUID, uuid4

import uvicorn

from . import billing
from .settings import settings
from .waffo import BridgeError, WaffoTest


def make_config(adapter):
    if not billing.sandbox_database(settings.public_origin):
        raise BridgeError('loopback_test_database_required')
    return billing.BillingConfig(adapter, (billing.BillingPlan('waffo-test-cloud-30d', 'waffo-test-v1',
                                                              adapter.catalog_amount()),),
                                 checkout_enabled=True, sandbox_origin=settings.public_origin)


def install(app, config):
    from .db import connect
    from .migrations import migrate_provider_checkout
    from .waffo_routes import mount_routes
    if not config.sandbox_origin or not billing.sandbox_database(config.origin):
        raise BridgeError('loopback_test_database_required')
    lifespan = app.router.lifespan_context

    @asynccontextmanager
    async def sandbox_lifespan(app):
        async with lifespan(app):
            with connect() as conn:
                conn.execute("SELECT pg_advisory_xact_lock(hashtext('weekglass_schema'))")
                migrate_provider_checkout(conn)
            yield

    app.router.lifespan_context = sandbox_lifespan
    app.state.billing = config
    mount_routes(app)


def new_order_link(config):
    from . import auth, db
    from .billing_routes import _order_link
    user = 'waffo-lab-' + uuid4().hex
    account_id = auth.create_account(user, secrets.token_urlsafe(32))
    with db.connect() as conn:
        account = billing.lock_account(conn, UUID(account_id))
        plan, = config.plans
        order = billing.create_checkout(conn, account, config, uuid4(), {
            'plan_id': plan.plan_id, 'purchase_mode': 'single', 'terms_version': plan.terms_version,
        })
        return _order_link(conn, order, config)['url']


def main():
    parser = argparse.ArgumentParser(description='WeekGlass local Waffo Test checkout')
    parser.add_argument('action', choices=('check', 'serve', 'new-order-link'))
    args = parser.parse_args()
    try:
        if not billing.sandbox_database(settings.public_origin):
            raise BridgeError('loopback_test_database_required')
        config = make_config(WaffoTest.load())
    except BridgeError as error:
        parser.exit(1, f'Waffo Test: {error}\n')
    amount = config.plans[0].amount_minor
    print(f'Waffo Test CNY price verified: {amount // 100}.{amount % 100:02}', flush=True)
    if args.action == 'serve':
        from .main import app
        install(app, config)
        uvicorn.run(app, host='127.0.0.1', port=urlsplit(config.origin).port, proxy_headers=False, access_log=False)
    elif args.action == 'new-order-link':
        print(new_order_link(config))


if __name__ == '__main__':
    main()
