"""Operator CLI. Passwords are read from a private file or terminal, never argv."""
import argparse
from datetime import datetime, timedelta, timezone
import getpass
import json
from pathlib import Path
from uuid import UUID
from . import auth, db


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
        if not 0 <= args.days <= 366:
            parser.error('days must be between 0 and 366')
        expiry = datetime.now(timezone.utc) + timedelta(days=args.days)
        with db.connect() as conn:
            row = conn.execute('UPDATE accounts SET grant_until=%s WHERE account_id=%s RETURNING account_id', (expiry, args.account_id)).fetchone()
            if not row:
                parser.error('Account does not exist')
        print(json.dumps({'account_id': str(args.account_id), 'grant_until': expiry.isoformat(), 'billing_enabled': False}))


if __name__ == '__main__':
    main()
