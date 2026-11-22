import base64
import time
from dataclasses import dataclass
from typing import Any

import httpx

from app.core.config import Settings


class ProviderError(RuntimeError):
    def __init__(self, code: str, user_message: str, status_code: int = 502, payload: dict[str, Any] | None = None):
        super().__init__(user_message)
        self.code = code
        self.user_message = user_message
        self.status_code = status_code
        self.payload = payload or {}


@dataclass
class ProviderResult:
    status_code: int
    payload: dict[str, Any]


class ArkSeedanceProvider:
    """Client for ModelArk's asynchronous video-generation API."""

    def __init__(self, settings: Settings, api_key: str | None = None):
        self.settings = settings
        self.api_key = (api_key if api_key is not None else settings.ark_api_key).strip()

    def build_payload(self, *, model: str, prompt: str, resolution: str, aspect_ratio: str, references: list[tuple[bytes, str, str | None]], parameters: dict[str, Any]) -> dict[str, Any]:
        content: list[dict[str, Any]] = [{"type": "text", "text": prompt.strip()}]
        roles = parameters.get("reference_roles")
        if not isinstance(roles, list):
            roles = []
        for index, (data, mime, public_url) in enumerate(references):
            encoded = public_url or f"data:{mime.lower()};base64,{base64.b64encode(data).decode()}"
            if mime.startswith("video/"):
                if not public_url:
                    raise ProviderError("video_url_required", "Referenzfilme müssen über den C-Dance-Server erreichbar sein.", 422)
                content.append({"type": "video_url", "role": "reference_video", "video_url": {"url": encoded}})
            elif mime.startswith("audio/"):
                if not public_url:
                    raise ProviderError("audio_url_required", "Referenzaudio muss über den C-Dance-Server erreichbar sein.", 422)
                content.append({"type": "audio_url", "role": "reference_audio", "audio_url": {"url": encoded}})
            else:
                role = roles[index] if index < len(roles) else "reference_image"
                if role not in {"first_frame", "last_frame", "reference_image"}:
                    role = "reference_image"
                content.append({"type": "image_url", "role": role, "image_url": {"url": encoded}})
        payload: dict[str, Any] = {
            "model": model,
            "content": content,
            "generate_audio": bool(parameters.get("generate_audio", self.settings.seedance_generate_audio)),
            "ratio": "adaptive" if aspect_ratio == "auto" else aspect_ratio,
            "resolution": resolution,
            "duration": int(parameters.get("duration", self.settings.seedance_default_duration)),
            "watermark": bool(parameters.get("watermark", self.settings.seedance_watermark)),
            "output_format": parameters.get("output_format", "mp4"),
        }
        for key in ("seed", "camera_fixed", "service_tier"):
            if key in parameters:
                payload[key] = parameters[key]
        return payload

    def create_task(self, payload: dict[str, Any]) -> ProviderResult:
        body, status = self._request("POST", self.settings.seedance_endpoint, json=payload)
        task_id = body.get("id")
        if not isinstance(task_id, str) or not task_id:
            raise ProviderError("missing_task_id", "C-Dance hat keine gültige Auftragsnummer erhalten.", 502, body)
        return ProviderResult(status, body)

    def retrieve_task(self, task_id: str) -> ProviderResult:
        body, status = self._request("GET", f"{self.settings.seedance_endpoint.rstrip('/')}/{task_id}")
        return ProviderResult(status, body)

    def wait_for_task(self, task_id: str) -> ProviderResult:
        deadline = time.monotonic() + self.settings.provider_timeout_seconds
        while time.monotonic() < deadline:
            result = self.retrieve_task(task_id)
            status = str(result.payload.get("status", "")).lower()
            if status == "succeeded":
                content = result.payload.get("content")
                if not isinstance(content, dict) or not isinstance(content.get("video_url"), str):
                    raise ProviderError("missing_video_url", "C-Dance hat keine Videodatei erhalten.", 502, result.payload)
                return result
            if status in {"failed", "cancelled", "expired"}:
                error = result.payload.get("error") if isinstance(result.payload.get("error"), dict) else {}
                code = str(error.get("code", "provider_failed"))
                message = str(error.get("message", ""))
                raise ProviderError(code, self._translate_error(result.status_code, code, message), result.status_code, result.payload)
            time.sleep(self.settings.provider_poll_interval_seconds)
        raise ProviderError("provider_timeout", "Die Filmgenerierung dauert ungewöhnlich lange. Der Auftrag wurde beendet; bitte erneut versuchen.", 504)

    def _request(self, method: str, url: str, **kwargs) -> tuple[dict[str, Any], int]:
        if not self.api_key:
            raise ProviderError("provider_not_configured", "C-Dance ist noch nicht konfiguriert. Bitte den API-Key unter Einstellungen hinterlegen.", 503)
        timeout = httpx.Timeout(connect=20, read=90, write=120, pool=20)
        try:
            with httpx.Client(timeout=timeout) as client:
                response = client.request(method, url, headers={"Authorization": f"Bearer {self.api_key}", "Content-Type": "application/json"}, **kwargs)
        except httpx.TimeoutException as exc:
            raise ProviderError("provider_timeout", "Der Videoanbieter hat nicht rechtzeitig geantwortet.", 504) from exc
        except httpx.HTTPError as exc:
            raise ProviderError("provider_unreachable", "Der Videoanbieter ist momentan nicht erreichbar.", 502) from exc
        try:
            body = response.json()
        except ValueError:
            body = {"raw": response.text[:4000]}
        if response.is_error:
            error = body.get("error") if isinstance(body.get("error"), dict) else {}
            code = str(error.get("code", "provider_error"))
            message = str(error.get("message", ""))
            raise ProviderError(code, self._translate_error(response.status_code, code, message), response.status_code, body)
        return body, response.status_code

    @staticmethod
    def _translate_error(status: int, code: str, message: str) -> str:
        lowered = f"{code} {message}".lower()
        if status in (401, 403):
            return "Die Anmeldung beim Videoanbieter ist ungültig oder nicht für Seedance freigeschaltet."
        if status == 429:
            return "Das Film-Limit ist gerade erreicht. Bitte kurz warten und erneut versuchen."
        if "sensitive" in lowered or "policy" in lowered:
            return "Die Anfrage wurde durch die Inhaltsrichtlinien des Videoanbieters abgelehnt."
        if "balance" in lowered or "quota" in lowered:
            return "Für die Filmgenerierung ist nicht genügend Guthaben oder Kontingent verfügbar."
        if status == 400:
            return "Der Videoanbieter konnte diese Kombination aus Prompt, Referenzen und Einstellungen nicht verarbeiten."
        return "Die Filmgenerierung ist beim Anbieter fehlgeschlagen."


def safe_provider_payload(payload: dict[str, Any]) -> dict[str, Any]:
    result = dict(payload)
    safe_content: list[dict[str, Any]] = []
    for item in result.get("content", []):
        safe_item = dict(item)
        for key in ("image_url", "video_url", "audio_url"):
            value = safe_item.get(key)
            if isinstance(value, dict) and isinstance(value.get("url"), str) and value["url"].startswith("data:"):
                safe_item[key] = {"url": "[embedded media]"}
        safe_content.append(safe_item)
    result["content"] = safe_content
    return result
