"""Operator CLI. Passwords are read from a private file or terminal, never argv."""
import argparse
from datetime import timedelta
import getpass
import json
from pathlib import Path
from uuid import UUID
from . import auth, console_sessions, db
from .billing import ANNUAL_PERIOD_SECONDS
from .entitlements import set_grant_until
from .protocol import now


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest='command', required=True)
    create = commands.add_parser('create-account')
    create.add_argument('username')
    create.add_argument('--password-file', type=Path)
    reset = commands.add_parser('reset-password')
    reset.add_argument('username')
    reset.add_argument('--password-file', type=Path)
    grant = commands.add_parser('grant')
    grant.add_argument('account_id', type=UUID)
    grant.add_argument('--days', type=int, required=True)
    owner = commands.add_parser('set-owner', help='Appoint an existing WeekGlass account as console owner')
    owner.add_argument('account_id', type=UUID)
    commands.add_parser('clear-owner', help='Remove console owner access')
    commands.add_parser('init-db')
    args = parser.parse_args()
    db.init_schema()
    with db.connect() as conn:
        auth.init_schema(conn)
    if args.command in ('create-account', 'reset-password'):
        password = args.password_file.read_text(encoding='utf-8').strip() if args.password_file else getpass.getpass('New password: ')
        result = auth.create_account(args.username, password) if args.command == 'create-account' else auth.reset_password(args.username, password)
        print(json.dumps({'account_id': result, 'username': args.username}))
    elif args.command == 'grant':
        if args.days < 0:
            parser.error('days must be non-negative')
        with db.connect() as conn:
            try:
                instant = now()
                end = instant + timedelta(days=args.days) if args.days else None
                if end:
                    end + timedelta(seconds=ANNUAL_PERIOD_SECONDS)
                row = set_grant_until(conn, args.account_id, end, instant)
            except OverflowError:
                parser.error('expiry date is outside the supported calendar')
            if not row:
                parser.error('Account does not exist')
        expiry = row['grant_until']
        print(json.dumps({'account_id': str(args.account_id), 'grant_until': expiry.isoformat() if expiry else None,
                          'billing_enabled': False}))
    elif args.command in ('set-owner', 'clear-owner'):
        with db.connect() as conn:
            console_sessions.lock_owner_changes(conn)
            if args.command == 'clear-owner':
                conn.execute('DELETE FROM web_owner')
                result = None
            else:
                result = args.account_id
                credentials = auth.locked_credentials(conn, result)
                if not credentials or not credentials['enabled']:
                    parser.error('An enabled WeekGlass account is required')
                conn.execute('''INSERT INTO web_owner(account_id) VALUES (%s) ON CONFLICT (singleton)
                  DO UPDATE SET account_id=excluded.account_id''', (result,))
        print(json.dumps({'account_id': str(result) if result else None}))


if __name__ == '__main__':
    main()
