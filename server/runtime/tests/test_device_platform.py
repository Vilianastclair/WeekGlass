from uuid import uuid4

from fastapi import FastAPI
from fastapi.testclient import TestClient
import pytest

from weekglass_server import auth
from weekglass_server.protocol import DEVICE_PLATFORM_LABELS


@pytest.mark.parametrize('platform,label', [
    ('windows', 'Windows'), ('android', 'Android'), ('macos', 'macOS'),
])
def test_device_metadata_uses_the_public_platform_contract(monkeypatch, platform, label):
    app = FastAPI()
    app.include_router(auth.router)
    identity = {'account_id': str(uuid4())}
    app.dependency_overrides[auth.get_identity] = lambda: identity
    written = []

    def update(device_id, body, authenticated):
        written.append((device_id, body, authenticated))
        return body

    monkeypatch.setattr(auth, '_update_device', update)
    device_id = str(uuid4())
    data = {'device_id': device_id, 'platform': platform,
            'display_name': f'WeekGlass {label}', 'app_version': '0.22.6+55'}
    with TestClient(app) as client:
        response = client.patch(f'/v1/devices/{device_id}', json=data)
        unknown = client.patch(f'/v1/devices/{device_id}', json={**data, 'platform': 'other'})
    assert response.status_code == 200
    assert response.json() == data
    assert unknown.status_code == 422
    assert written == [(device_id, data, identity)]
    assert DEVICE_PLATFORM_LABELS[platform] == label
