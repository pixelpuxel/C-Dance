import io

from PIL import Image

from app.core.config import get_settings
from app.services.generations import normalize_model
from app.services.images import prepare_provider_image
from app.services.provider import ArkSeedanceProvider, safe_provider_payload
import app.services.provider as provider_module
import app.tasks as tasks_module
from app.tasks import _download_video


def test_provider_payload_uses_official_seedance_fields():
    provider = ArkSeedanceProvider(get_settings())
    payload = provider.build_payload(
        model="dreamina-seedance-2-5-260628",
        prompt="Eine ruhige Kamerafahrt",
        resolution="720p",
        aspect_ratio="16:9",
        references=[(b"bytes", "image/png", None)],
        parameters={"duration": 10, "generate_audio": True},
    )
    assert payload["model"] == "dreamina-seedance-2-5-260628"
    assert payload["resolution"] == "720p"
    assert payload["ratio"] == "16:9"
    assert payload["duration"] == 10
    assert payload["generate_audio"] is True
    assert payload["content"][0] == {"type": "text", "text": "Eine ruhige Kamerafahrt"}
    assert payload["content"][1]["image_url"]["url"].startswith("data:image/png;base64,")
    assert safe_provider_payload(payload)["content"][1]["image_url"]["url"] == "[embedded media]"


def test_provider_uses_public_url_for_reference_video():
    provider = ArkSeedanceProvider(get_settings())
    payload = provider.build_payload(
        model="dreamina-seedance-2-5-260628",
        prompt="Weiterbewegen",
        resolution="720p",
        aspect_ratio="auto",
        references=[(b"not-embedded", "video/mp4", "https://cdance.example/reference.mp4")],
        parameters={"duration": 5},
    )
    assert payload["content"][1] == {
        "type": "video_url",
        "role": "reference_video",
        "video_url": {"url": "https://cdance.example/reference.mp4"},
    }


def test_seedance_model_ids_are_normalized():
    settings = get_settings()
    assert normalize_model("dreamina-seedance-2-5-260628", settings) == settings.seedance_model
    assert normalize_model("dreamina-seedance-2-5-flash-261115", settings) == settings.seedance_flash_model
    assert normalize_model("dreamina-seedance-2-0-260128", settings) == settings.seedance_20_model
    assert normalize_model("dreamina-seedance-2-0-fast-260128", settings) == settings.seedance_fast_model


def test_provider_reference_is_normalized_to_jpeg():
    source = io.BytesIO()
    Image.new("RGBA", (80, 60), (255, 0, 0, 120)).save(source, "PNG")
    data, mime = prepare_provider_image(source.getvalue())
    assert mime == "image/jpeg"
    with Image.open(io.BytesIO(data)) as image:
        assert image.format == "JPEG"
        assert image.mode == "RGB"


def test_provider_creates_and_retrieves_task(monkeypatch):
    responses = [
        {"id": "cgt-test"},
        {"id": "cgt-test", "status": "succeeded", "content": {"video_url": "https://example.test/result.mp4"}},
    ]

    class FakeClient:
        def __init__(self, **_kwargs): pass
        def __enter__(self): return self
        def __exit__(self, *_args): return False
        def request(self, method, url, **_kwargs):
            return provider_module.httpx.Response(200, request=provider_module.httpx.Request(method, url), json=responses.pop(0))

    monkeypatch.setattr(provider_module.httpx, "Client", FakeClient)
    provider = ArkSeedanceProvider(get_settings(), api_key="test-key")
    created = provider.create_task({"model": "test", "content": []})
    assert created.payload["id"] == "cgt-test"
    finished = provider.wait_for_task("cgt-test")
    assert finished.payload["content"]["video_url"].endswith("result.mp4")


def test_video_download_reconnects_after_tls_timeout(monkeypatch):
    attempts = 0

    class FakeClient:
        def __init__(self, **_kwargs): pass
        def __enter__(self): return self
        def __exit__(self, *_args): return False
        def get(self, url):
            nonlocal attempts
            attempts += 1
            if attempts == 1:
                raise tasks_module.httpx.ConnectTimeout("TLS timeout")
            return tasks_module.httpx.Response(200, request=tasks_module.httpx.Request("GET", url), content=b"mp4-result", headers={"content-type": "video/mp4"})

    monkeypatch.setattr(tasks_module.httpx, "Client", FakeClient)
    monkeypatch.setattr(tasks_module.time, "sleep", lambda _seconds: None)
    data, mime = _download_video("https://example.test/result.mp4", timeout=30)
    assert data == b"mp4-result"
    assert mime == "video/mp4"
    assert attempts == 2
