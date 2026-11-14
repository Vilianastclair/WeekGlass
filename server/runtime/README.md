# WeekGlass sync API

FastAPI and PostgreSQL implement account authorization, device management, atomic sync batches, incremental change feeds, cloud data export and entitlement checks.

See [self-hosting](../README.md) for container configuration. The server applies versioned schema changes against the configured database. To initialize the schema or provision an account manually, run these commands in the configured API container:

```sh
python -m weekglass_server.admin init-db
python -m weekglass_server.admin create-account example-user
```

For tests, install `requirements-test.txt` and run `python -m pytest tests` from this directory. Tests that exercise the database require a dedicated disposable PostgreSQL database whose name ends in `_test`. Never run the suite against a live database.
