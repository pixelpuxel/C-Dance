import base64
import hashlib
import hmac
import html
import ipaddress
import json
import os
from pathlib import Path
import secrets
import socket
import time
from typing import Any, Literal
from urllib.parse import parse_qsl, urlencode, urlparse, urlsplit, urlunsplit

import httpx
from pydantic import AnyHttpUrl
from mcp.server import MCPServer
from mcp.server.auth.provider import (
    AccessToken,
    AuthorizationCode,
    AuthorizationParams,
    OAuthAuthorizationServerProvider,
    RefreshToken,
    construct_redirect_uri,
)
from mcp.server.auth.settings import AuthSettings, ClientRegistrationOptions, RevocationOptions
from mcp.server.transport_security import TransportSecuritySettings
from mcp.shared.auth import OAuthClientInformationFull, OAuthToken
from mcp.types import ResourceLink, ToolAnnotations
from starlette.requests import Request
from starlette.responses import HTMLResponse, RedirectResponse

BACKEND_URL = os.environ.get("BACKEND_URL", "http://backend:8000/api/v1").rstrip("/")
BACKEND_API_KEY = os.environ.get("MCP_BACKEND_API_KEY", "")
POLL_INTERVAL = float(os.environ.get("MCP_POLL_INTERVAL", "1.5"))
POLL_TIMEOUT = int(os.environ.get("MCP_POLL_TIMEOUT", "2100"))
PUBLIC_HOST = os.environ.get("MCP_PUBLIC_HOST", "cdance.schreiber.info")
PUBLIC_BASE_URL = f"https://{PUBLIC_HOST}"
PUBLIC_MCP_URL = f"{PUBLIC_BASE_URL}/mcp"
OAUTH_PASSWORD = os.environ.get("MCP_ACCESS_TOKEN", "")
OAUTH_STATE_PATH = Path(os.environ.get("MCP_OAUTH_STATE", "/data/oauth-state.json"))
MAX_FILE_BYTES = 200 * 1024 * 1024

READ_ONLY = ToolAnnotations(readOnlyHint=True, destructiveHint=False, idempotentHint=True)
SAFE_WRITE = ToolAnnotations(readOnlyHint=False, destructiveHint=False, idempotentHint=False)
DESTRUCTIVE = ToolAnnotations(readOnlyHint=False, destructiveHint=True, idempotentHint=True)

class PrivateOAuthProvider(OAuthAuthorizationServerProvider[AuthorizationCode, RefreshToken, AccessToken]):
    """Small persistent OAuth 2.1 provider guarded by the private MCP password."""

    def __init__(self) -> None:
        self.clients: dict[str, OAuthClientInformationFull] = {}
        self.codes: dict[str, AuthorizationCode] = {}
        self.pending: dict[str, tuple[OAuthClientInformationFull, AuthorizationParams, float]] = {}
        self.approved_redirects: dict[str, str] = {}
        self.access_tokens: dict[str, AccessToken] = {}
        self.refresh_tokens: dict[str, RefreshToken] = {}
        self._load()

    async def get_client(self, client_id: str) -> OAuthClientInformationFull | None:
        return self.clients.get(client_id)

    async def register_client(self, client_info: OAuthClientInformationFull) -> None:
        if not client_info.client_id:
            raise ValueError("OAuth-Client besitzt keine ID")
        self.clients[client_info.client_id] = client_info
        self._save()

    async def authorize(self, client: OAuthClientInformationFull, params: AuthorizationParams) -> str:
        request_id = secrets.token_urlsafe(32)
        self.pending[request_id] = (client, params, time.time() + 600)
        return f"{PUBLIC_BASE_URL}/oauth/consent?request={request_id}"

    def approve(self, request_id: str, password: str) -> str:
        pending = self.pending.pop(request_id, None)
        if not pending or pending[2] < time.time():
            raise ValueError("Die OAuth-Anfrage ist abgelaufen. Bitte die Verbindung erneut starten.")
        client, params, _ = pending
        if not OAUTH_PASSWORD or not hmac.compare_digest(password, OAUTH_PASSWORD):
            self.pending[request_id] = pending
            raise PermissionError("Der Zugriffsschlüssel ist nicht korrekt.")
        if not client.client_id:
            raise ValueError("OAuth-Client besitzt keine ID")
        code = AuthorizationCode(
            code=f"code_{secrets.token_urlsafe(32)}",
            client_id=client.client_id,
            scopes=params.scopes or ["cdance"],
            expires_at=time.time() + 300,
            code_challenge=params.code_challenge,
            redirect_uri=params.redirect_uri,
            redirect_uri_provided_explicitly=params.redirect_uri_provided_explicitly,
            resource=params.resource or PUBLIC_MCP_URL,
            subject="cdance-owner",
        )
        self.codes[code.code] = code
        return construct_redirect_uri(str(params.redirect_uri), code=code.code, state=params.state)

    def approve_trusted(self, request_id: str) -> None:
        """Approve from the container's loopback interface without exposing the password to a browser."""
        self.approved_redirects[request_id] = self.approve(request_id, OAUTH_PASSWORD)

    async def load_authorization_code(self, client: OAuthClientInformationFull, authorization_code: str) -> AuthorizationCode | None:
        code = self.codes.get(authorization_code)
        return code if code and code.expires_at >= time.time() else None

    async def exchange_authorization_code(self, client: OAuthClientInformationFull, authorization_code: AuthorizationCode) -> OAuthToken:
        self.codes.pop(authorization_code.code, None)
        access = self._mint_access_token(authorization_code.client_id, authorization_code.scopes, authorization_code.resource)
        refresh = self._mint_refresh_token(authorization_code.client_id, authorization_code.scopes, authorization_code.resource)
        self._save()
        return OAuthToken(
            access_token=access.token, token_type="Bearer", expires_in=3600,
            refresh_token=refresh.token, scope=" ".join(access.scopes),
        )

    async def load_access_token(self, token: str) -> AccessToken | None:
        access = self.access_tokens.get(_token_hash(token))
        if access and (access.expires_at is None or access.expires_at >= time.time()):
            return access
        return None

    async def load_refresh_token(self, client: OAuthClientInformationFull, refresh_token: str) -> RefreshToken | None:
        token = self.refresh_tokens.get(_token_hash(refresh_token))
        if token and token.client_id == client.client_id and (token.expires_at is None or token.expires_at >= time.time()):
            return token
        return None

    async def exchange_refresh_token(self, client: OAuthClientInformationFull, refresh_token: RefreshToken, scopes: list[str]) -> OAuthToken:
        self.refresh_tokens.pop(_token_hash(refresh_token.token), None)
        granted = scopes or refresh_token.scopes
        access = self._mint_access_token(refresh_token.client_id, granted, refresh_token.resource)
        new_refresh = self._mint_refresh_token(refresh_token.client_id, granted, refresh_token.resource)
        self._save()
        return OAuthToken(
            access_token=access.token, token_type="Bearer", expires_in=3600,
            refresh_token=new_refresh.token, scope=" ".join(granted),
        )

    async def revoke_token(self, token: AccessToken | RefreshToken) -> None:
        self.access_tokens.pop(_token_hash(token.token), None)
        self.refresh_tokens.pop(_token_hash(token.token), None)
        self._save()

    def _mint_access_token(self, client_id: str, scopes: list[str], resource: str | None) -> AccessToken:
        raw = f"access_{secrets.token_urlsafe(32)}"
        token = AccessToken(
            token=raw, client_id=client_id, scopes=scopes, expires_at=int(time.time()) + 3600,
            resource=resource or PUBLIC_MCP_URL, subject="cdance-owner",
        )
        self.access_tokens[_token_hash(raw)] = token
        return token

    def _mint_refresh_token(self, client_id: str, scopes: list[str], resource: str | None) -> RefreshToken:
        raw = f"refresh_{secrets.token_urlsafe(32)}"
        token = RefreshToken(
            token=raw, client_id=client_id, scopes=scopes, expires_at=int(time.time()) + 2_592_000,
            resource=resource or PUBLIC_MCP_URL, subject="cdance-owner",
        )
        self.refresh_tokens[_token_hash(raw)] = token
        return token

    def _load(self) -> None:
        try:
            payload = json.loads(OAUTH_STATE_PATH.read_text())
            self.clients = {key: OAuthClientInformationFull.model_validate(value) for key, value in payload.get("clients", {}).items()}
            self.access_tokens = {key: AccessToken.model_validate(value) for key, value in payload.get("access_tokens", {}).items()}
            self.refresh_tokens = {key: RefreshToken.model_validate(value) for key, value in payload.get("refresh_tokens", {}).items()}
        except (FileNotFoundError, ValueError, OSError):
            return

    def _save(self) -> None:
        OAUTH_STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "clients": {key: value.model_dump(mode="json") for key, value in self.clients.items()},
            "access_tokens": {key: value.model_dump(mode="json") for key, value in self.access_tokens.items()},
            "refresh_tokens": {key: value.model_dump(mode="json") for key, value in self.refresh_tokens.items()},
        }
        temporary = OAUTH_STATE_PATH.with_suffix(".tmp")
        temporary.write_text(json.dumps(payload))
        temporary.chmod(0o600)
        temporary.replace(OAUTH_STATE_PATH)


def _token_hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


oauth_provider = PrivateOAuthProvider()

mcp = MCPServer(
    "C-Dance",
    instructions=(
        "Bedient die private C-Dance-API für Seedance-Filmgenerierung. Nutze Lese-Werkzeuge zuerst. "
        "Vor Löschaktionen muss der Mensch ausdrücklich bestätigen. Generierungen, Prompts, "
        "Referenzmedien, Favoriten und Sterne entsprechen der iPhone-/iPad-App."
    ),
    auth_server_provider=oauth_provider,
    auth=AuthSettings(
        issuer_url=AnyHttpUrl(PUBLIC_BASE_URL),
        resource_server_url=AnyHttpUrl(PUBLIC_MCP_URL),
        required_scopes=["cdance"],
        client_registration_options=ClientRegistrationOptions(
            enabled=True, valid_scopes=["cdance"], default_scopes=["cdance"],
        ),
        revocation_options=RevocationOptions(enabled=True),
        validate_token_resource=True,
    ),
)


@mcp.custom_route("/oauth/consent", methods=["GET", "POST"])
async def oauth_consent(request: Request):
    request_id = request.query_params.get("request", "")
    if request.method == "GET" and request_id in oauth_provider.approved_redirects:
        return RedirectResponse(oauth_provider.approved_redirects.pop(request_id), status_code=302)
    error = ""
    if request.method == "POST":
        form = await request.form()
        request_id = str(form.get("request", ""))
        try:
            redirect = oauth_provider.approve(request_id, str(form.get("password", "")))
            return RedirectResponse(redirect, status_code=302)
        except (ValueError, PermissionError) as exc:
            error = str(exc)
    safe_request = html.escape(request_id, quote=True)
    safe_error = f'<p style="color:#ff6b6b">{html.escape(error)}</p>' if error else ""
    return HTMLResponse(f"""<!doctype html><html lang=de><meta name=viewport content='width=device-width'>
    <title>C-Dance verbinden</title><style>
    body{{font:17px -apple-system,BlinkMacSystemFont,sans-serif;background:#090909;color:#fff;display:grid;place-items:center;min-height:100vh;margin:0}}
    main{{width:min(420px,calc(100% - 48px));background:#1c1c1e;padding:28px;border-radius:24px}}
    input,button{{box-sizing:border-box;width:100%;padding:14px;border-radius:12px;font:inherit}}
    input{{background:#2c2c2e;color:#fff;border:1px solid #555;margin:10px 0 16px}}button{{background:#b9f52f;border:0;font-weight:700}}
    small{{color:#aaa}}</style><main><h1>C-Dance verbinden</h1>
    <p>Erlaube ChatGPT den Zugriff auf deinen privaten C-Dance-Verlauf und die Filmwerkzeuge.</p>{safe_error}
    <form method=post><input type=hidden name=request value='{safe_request}'>
    <label>Zugriffsschlüssel<input name=password type=password required autocomplete=current-password></label>
    <button type=submit>Verbinden</button></form><p><small>Der Schlüssel wird nur zur Freigabe geprüft und nicht an ChatGPT weitergegeben.</small></p>
    </main></html>""")


@mcp.custom_route("/oauth/internal-approve", methods=["POST"])
async def oauth_internal_approve(request: Request):
    if not request.client or request.client.host not in {"127.0.0.1", "::1"}:
        return HTMLResponse("Nicht erlaubt", status_code=403)
    form = await request.form()
    try:
        oauth_provider.approve_trusted(str(form.get("request", "")))
    except (ValueError, PermissionError) as exc:
        return HTMLResponse(html.escape(str(exc)), status_code=400)
    return HTMLResponse("Freigegeben")


class Backend:
    def __init__(self):
        if not BACKEND_API_KEY or "REPLACE" in BACKEND_API_KEY or "CHANGE_ME" in BACKEND_API_KEY:
            raise RuntimeError("MCP_BACKEND_API_KEY fehlt")

    def request(self, method: str, path: str, **kwargs) -> Any:
        headers = {"X-API-Key": BACKEND_API_KEY, **kwargs.pop("headers", {})}
        with httpx.Client(timeout=360) as client:
            response = client.request(method, f"{BACKEND_URL}{path}", headers=headers, **kwargs)
        if response.is_error:
            try:
                payload = response.json()
                message = payload.get("error", payload.get("detail", {})).get("message")
            except (ValueError, AttributeError):
                message = None
            raise RuntimeError(message or f"Backend-Fehler {response.status_code}")
        return response.json() if response.content else None

    def upload(self, content: bytes, mime: str, name: str) -> dict[str, Any]:
        return self.request("POST", "/images", files={"image": (name, content, mime)})

    def submit(self, path: str, data: dict[str, Any]) -> dict[str, Any]:
        form = {
            key: value if isinstance(value, str) else json.dumps(value)
            for key, value in data.items()
            if value is not None
        }
        generation = self.request("POST", path, data=form)
        return self.wait(generation["id"])

    def wait(self, generation_id: str) -> dict[str, Any]:
        deadline = time.monotonic() + POLL_TIMEOUT
        while time.monotonic() < deadline:
            generation = self.request("GET", f"/generations/{generation_id}")
            if generation["status"] == "completed":
                return _public_result(generation)
            if generation["status"] == "failed":
                raise RuntimeError(generation.get("error_message") or "Filmgenerierung fehlgeschlagen")
            time.sleep(POLL_INTERVAL)
        return {
            "id": generation_id,
            "status": "processing",
            "message": "Die Generierung läuft weiter. Mit get_generation später erneut abrufen.",
        }


def backend() -> Backend:
    return Backend()


@mcp.tool(annotations=SAFE_WRITE)
def generate_video(
    prompt: str,
    reference_image_ids: list[str] | None = None,
    reference_asset_ids: list[str] | None = None,
    reference_urls: list[str] | None = None,
    reference_images_base64: list[str] | None = None,
    aspect_ratio: str = "auto",
    resolution: str = "720p",
    duration: int = 5,
    generate_audio: bool = True,
    model: str | None = None,
) -> dict[str, Any]:
    """Generiert einen Film und wartet nach Möglichkeit bis zum fertigen MP4-Ergebnis."""
    api = backend()
    image_ids = _collect_image_ids(
        api, reference_image_ids or [], reference_asset_ids or [],
        reference_urls or [], reference_images_base64 or [],
    )
    return api.submit("/generate", {
        "prompt": prompt, "final_prompt": prompt, "image_ids": image_ids, "template_ids": [],
        "aspect_ratio": aspect_ratio, "resolution": resolution, "model": model,
        "parameters": {"duration": duration, "generate_audio": generate_audio},
    })


@mcp.tool(annotations=SAFE_WRITE)
def generate_with_prompt_templates(
    prompt_template_ids: list[str],
    additional_text: str = "",
    reference_image_ids: list[str] | None = None,
    reference_asset_ids: list[str] | None = None,
    reference_urls: list[str] | None = None,
    reference_images_base64: list[str] | None = None,
    aspect_ratio: str = "auto",
    resolution: str = "720p",
    duration: int = 5,
    generate_audio: bool = True,
    model: str | None = None,
) -> dict[str, Any]:
    """Kombiniert gespeicherte Prompt-Bausteine in Reihenfolge und generiert damit einen Film."""
    api = backend()
    templates = {item["id"]: item for item in api.request("GET", "/prompts")}
    missing = [item for item in prompt_template_ids if item not in templates]
    if missing:
        raise ValueError(f"Unbekannte Prompt-ID(s): {', '.join(missing)}")
    parts = [templates[item]["text"] for item in prompt_template_ids]
    if additional_text.strip():
        parts.append(additional_text.strip())
    final_prompt = "\n\n".join(parts)
    if not final_prompt:
        raise ValueError("Mindestens ein Prompt-Baustein oder zusätzlicher Text ist erforderlich")
    image_ids = _collect_image_ids(
        api, reference_image_ids or [], reference_asset_ids or [],
        reference_urls or [], reference_images_base64 or [],
    )
    return api.submit("/generate", {
        "prompt": additional_text, "final_prompt": final_prompt, "template_ids": prompt_template_ids,
        "image_ids": image_ids, "aspect_ratio": aspect_ratio, "resolution": resolution, "model": model,
        "parameters": {"duration": duration, "generate_audio": generate_audio},
    })


@mcp.tool(annotations=SAFE_WRITE)
def edit_video(
    generation_id: str,
    instruction: str,
    source_image_id: str | None = None,
    additional_reference_image_ids: list[str] | None = None,
    marked_image_url: str | None = None,
    marked_image_base64: str | None = None,
    aspect_ratio: str = "auto",
    resolution: str = "720p",
    duration: int = 5,
    generate_audio: bool = True,
    model: str | None = None,
) -> dict[str, Any]:
    """Bearbeitet einen Ergebnisfilm mit einer neuen Anweisung und optionalen Referenzen."""
    api = backend()
    source = api.request("GET", f"/generations/{generation_id}")
    result_images = _result_images(source)
    if not source_image_id and not result_images:
        raise ValueError("Die Generation besitzt kein Ergebnisbild")
    image_ids = [source_image_id or result_images[0]["id"]]
    image_ids.extend(additional_reference_image_ids or [])
    image_ids.extend(_upload_inputs(
        api, [marked_image_url] if marked_image_url else [],
        [marked_image_base64] if marked_image_base64 else [],
    ))
    return api.submit("/edit", {
        "prompt": instruction, "final_prompt": instruction, "parent_id": generation_id,
        "image_ids": image_ids, "template_ids": [], "aspect_ratio": aspect_ratio,
        "resolution": resolution, "model": model,
        "parameters": {"duration": duration, "generate_audio": generate_audio},
    })


@mcp.tool(annotations=SAFE_WRITE)
def create_variation(generation_id: str) -> dict[str, Any]:
    """Erstellt eine neue Variante aus dem Ergebnisbild einer Generation."""
    api = backend()
    generation = api.request("POST", f"/generations/{generation_id}/variation")
    return api.wait(generation["id"])


@mcp.tool(annotations=SAFE_WRITE)
def regenerate_video(generation_id: str) -> dict[str, Any]:
    """Führt den gespeicherten Request mit denselben Eingaben erneut aus."""
    api = backend()
    generation = api.request("POST", f"/generations/{generation_id}/regenerate")
    return api.wait(generation["id"])


@mcp.tool(annotations=READ_ONLY)
def get_generation(generation_id: str) -> dict[str, Any]:
    """Liefert Prompt, Referenzen, Status, Favorit, Sterne und Ergebnisdateien."""
    return _public_result(backend().request("GET", f"/generations/{generation_id}"))


@mcp.tool(annotations=READ_ONLY)
def list_generations(
    limit: int = 20,
    offset: int = 0,
    status: Literal["queued", "processing", "completed", "failed"] | None = None,
    favorites_only: bool = False,
    rating: int | None = None,
) -> dict[str, Any]:
    """Listet den Verlauf. Optional nach Status, Favoriten oder 1–5 Sternen filtern."""
    limit = min(max(limit, 1), 100)
    query = urlencode({key: value for key, value in {
        "limit": limit, "offset": max(offset, 0), "status": status,
    }.items() if value is not None})
    result = backend().request("GET", f"/generations?{query}")
    items = [_public_result(item) for item in result["items"]]
    if favorites_only:
        items = [item for item in items if item.get("favorite")]
    if rating is not None:
        if rating not in range(1, 6):
            raise ValueError("rating muss zwischen 1 und 5 liegen")
        items = [item for item in items if item.get("rating") == rating]
    return {**result, "items": items}


@mcp.tool(annotations=SAFE_WRITE)
def set_generation_preference(generation_id: str, favorite: bool = False, rating: int = 0) -> dict[str, Any]:
    """Setzt Favorit unabhängig von der optionalen Bewertung mit 1–5 Sternen; 0 entfernt Sterne."""
    if rating not in range(0, 6):
        raise ValueError("rating muss zwischen 0 und 5 liegen")
    return _public_result(backend().request(
        "PUT", f"/generations/{generation_id}/preference",
        json={"favorite": favorite, "rating": rating},
    ))


@mcp.tool(annotations=DESTRUCTIVE)
def delete_generation(generation_id: str, confirm: bool = False) -> dict[str, Any]:
    """Löscht Verlaufseintrag und ungeteilte Dateien dauerhaft. Nur mit confirm=true ausführen."""
    _require_confirmation(confirm)
    return backend().request("DELETE", f"/generations/{generation_id}")


@mcp.tool(annotations=READ_ONLY)
def list_models() -> dict[str, Any]:
    """Listet Modelle, Auflösungen, Seitenverhältnisse und Referenzlimits."""
    return backend().request("GET", "/models")


@mcp.tool(annotations=READ_ONLY)
def list_prompt_templates() -> list[dict[str, Any]]:
    """Liest alle Prompt-Bausteine vollständig mit Namen, Text, Kategorie und Tags vor."""
    return backend().request("GET", "/prompts")


@mcp.tool(annotations=SAFE_WRITE)
def create_prompt_template(
    name: str, text: str, description: str = "", category: str = "",
    tags: list[str] | None = None, favorite: bool = False, sort_order: int = 0,
) -> dict[str, Any]:
    """Legt einen Prompt-Baustein an."""
    return backend().request("POST", "/prompts", json=_prompt_payload(
        name, text, description, category, tags, favorite, sort_order,
    ))


@mcp.tool(annotations=SAFE_WRITE)
def update_prompt_template(
    prompt_id: str, name: str, text: str, description: str = "", category: str = "",
    tags: list[str] | None = None, favorite: bool = False, sort_order: int = 0,
) -> dict[str, Any]:
    """Ändert einen bestehenden Prompt-Baustein vollständig."""
    return backend().request("PUT", f"/prompts/{prompt_id}", json=_prompt_payload(
        name, text, description, category, tags, favorite, sort_order,
    ))


@mcp.tool(annotations=SAFE_WRITE)
def copy_prompt_template(prompt_id: str) -> dict[str, Any]:
    """Erstellt eine bearbeitbare Kopie eines Prompt-Bausteins."""
    return backend().request("POST", f"/prompts/{prompt_id}/copy")


@mcp.tool(annotations=DESTRUCTIVE)
def delete_prompt_template(prompt_id: str, confirm: bool = False) -> dict[str, bool]:
    """Löscht einen Prompt-Baustein dauerhaft. Nur mit confirm=true ausführen."""
    _require_confirmation(confirm)
    backend().request("DELETE", f"/prompts/{prompt_id}")
    return {"deleted": True}


@mcp.tool(annotations=READ_ONLY)
def list_reference_assets() -> list[dict[str, Any]]:
    """Listet die gespeicherte Referenzbild-Bibliothek mit abrufbaren Dateien."""
    return backend().request("GET", "/reference-assets")


@mcp.tool(annotations=SAFE_WRITE)
def create_reference_asset(
    name: str, category: str = "", image_id: str | None = None,
    image_url: str | None = None, image_base64: str | None = None,
) -> dict[str, Any]:
    """Speichert ein vorhandenes, per URL oder Base64 geliefertes Bild in der Referenzbibliothek."""
    api = backend()
    supplied = sum(value is not None for value in (image_id, image_url, image_base64))
    if supplied != 1:
        raise ValueError("Genau eine Bildquelle angeben: image_id, image_url oder image_base64")
    if not image_id:
        image_id = _upload_inputs(
            api, [image_url] if image_url else [], [image_base64] if image_base64 else [],
        )[0]
    return api.request("POST", "/reference-assets", data={
        "name": name, "category": category, "image_id": image_id,
    })


@mcp.tool(annotations=SAFE_WRITE)
def rename_reference_asset(asset_id: str, name: str) -> dict[str, Any]:
    """Benennt ein gespeichertes Referenzbild um."""
    return backend().request("PUT", f"/reference-assets/{asset_id}", json={"name": name})


@mcp.tool(annotations=DESTRUCTIVE)
def delete_reference_asset(asset_id: str, confirm: bool = False) -> dict[str, bool]:
    """Entfernt ein Bild aus der Referenzbibliothek. Nur mit confirm=true ausführen."""
    _require_confirmation(confirm)
    backend().request("DELETE", f"/reference-assets/{asset_id}")
    return {"deleted": True}


@mcp.tool(annotations=SAFE_WRITE)
def upload_media(
    image_url: str | None = None,
    image_base64: str | None = None,
    filename: str = "upload.png",
) -> dict[str, Any]:
    """Lädt ein Referenzbild oder einen Referenzfilm über eine öffentliche HTTPS-Datei-URL hoch; Bilder gehen auch als Base64."""
    if (image_url is None) == (image_base64 is None):
        raise ValueError("Genau eine Quelle angeben: image_url oder image_base64")
    if image_url:
        content, mime, remote_name = _safe_download(image_url)
        filename = remote_name or filename
    else:
        content, mime = _decode_image(image_base64 or "")
    return backend().upload(content, mime, filename)


@mcp.tool(annotations=READ_ONLY)
def list_uploaded_media(limit: int = 50) -> list[dict[str, Any]]:
    """Listet hochgeladene und erzeugte Medien mit IDs und Download-URLs."""
    return backend().request("GET", f"/images?limit={min(max(limit, 1), 100)}")


@mcp.tool(annotations=READ_ONLY)
def download_generation_file(
    generation_id: str,
    image_index: int = 0,
    format: Literal["original"] = "original",
) -> ResourceLink:
    """Gibt den Ergebnisfilm als anklickbare MP4-/MOV-Datei zurück."""
    generation = backend().request("GET", f"/generations/{generation_id}")
    images = _result_images(generation)
    if image_index < 0 or image_index >= len(images):
        raise ValueError("Bildindex außerhalb des gültigen Bereichs")
    image = images[image_index]
    url = image["download_url"]
    mime = image["mime_type"]
    extension = _extension(mime)
    return ResourceLink(
        name=f"cdance-{generation_id}-{image_index + 1}.{extension}",
        title="C-Dance-Ergebnisfilm",
        uri=url,
        description="Kurzlebig signierter Download-Link zum Ergebnisfilm.",
        mimeType=mime,
        size=image.get("byte_size"),
    )


@mcp.tool(annotations=READ_ONLY)
def get_app_settings() -> dict[str, Any]:
    """Liest die serverseitig synchronisierten App-Einstellungen."""
    return backend().request("GET", "/settings")


@mcp.tool(annotations=SAFE_WRITE)
def update_app_settings(
    auto_save_photos: bool = False, auto_save_album: bool = False,
    album_name: str = "C-Dance", default_model: str | None = None,
    default_resolution: str | None = None,
) -> dict[str, Any]:
    """Ändert die serverseitig synchronisierten App-Einstellungen."""
    return backend().request("PUT", "/settings", json={
        "auto_save_photos": auto_save_photos, "auto_save_album": auto_save_album,
        "album_name": album_name, "default_model": default_model,
        "default_resolution": default_resolution,
    })


@mcp.resource("cdance://generations/{generation_id}")
def generation_resource(generation_id: str) -> str:
    """Maschinenlesbare Metadaten und signierte Film-URLs einer Generation."""
    return json.dumps(_public_result(
        backend().request("GET", f"/generations/{generation_id}"),
    ), ensure_ascii=False, indent=2)


def _prompt_payload(
    name: str, text: str, description: str, category: str,
    tags: list[str] | None, favorite: bool, sort_order: int,
) -> dict[str, Any]:
    return {
        "name": name, "text": text, "description": description or None,
        "category": category or None, "tags": tags or [], "favorite": favorite,
        "sort_order": sort_order,
    }


def _collect_image_ids(
    api: Backend, image_ids: list[str], asset_ids: list[str],
    urls: list[str], encoded: list[str],
) -> list[str]:
    result = list(image_ids)
    if asset_ids:
        assets = {item["id"]: item for item in api.request("GET", "/reference-assets")}
        missing = [item for item in asset_ids if item not in assets]
        if missing:
            raise ValueError(f"Unbekannte Referenzbild-ID(s): {', '.join(missing)}")
        result.extend(assets[item]["image"]["id"] for item in asset_ids)
    result.extend(_upload_inputs(api, urls, encoded))
    return result


def _upload_inputs(api: Backend, urls: list[str], encoded_images: list[str]) -> list[str]:
    ids = []
    for index, url in enumerate(urls):
        content, mime, remote_name = _safe_download(url)
        uploaded = api.upload(content, mime, remote_name or f"reference-{index + 1}.{_extension(mime)}")
        ids.append(uploaded["id"])
    for index, encoded in enumerate(encoded_images):
        content, mime = _decode_image(encoded)
        uploaded = api.upload(content, mime, f"reference-base64-{index + 1}.{_extension(mime)}")
        ids.append(uploaded["id"])
    return ids


def _safe_download(url: str) -> tuple[bytes, str, str | None]:
    current = url
    with httpx.Client(timeout=30, follow_redirects=False) as client:
        for _ in range(4):
            parsed = _validate_public_https(current)
            response = client.get(current)
            if response.is_redirect:
                location = response.headers.get("location")
                if not location:
                    raise ValueError("Datei-Weiterleitung besitzt kein Ziel")
                current = str(response.url.join(location))
                continue
            response.raise_for_status()
            break
        else:
            raise ValueError("Zu viele Datei-Weiterleitungen")
    if len(response.content) > MAX_FILE_BYTES:
        raise ValueError("Die Mediendatei ist größer als 200 MB")
    mime = response.headers.get("content-type", "").split(";")[0].lower()
    if mime in {"", "application/octet-stream", "binary/octet-stream"}:
        mime = _detect_image_mime(response.content)
    if mime not in {
        "image/jpeg", "image/png", "image/webp", "image/gif", "image/bmp",
        "image/tiff", "image/heic", "image/heif", "video/mp4", "video/quicktime",
    }:
        raise ValueError("URL liefert kein unterstütztes Bild oder Video")
    filename = parsed.path.rsplit("/", 1)[-1] or None
    return response.content, mime, filename


def _validate_public_https(url: str):
    parsed = urlparse(url)
    if parsed.scheme != "https" or not parsed.hostname:
        raise ValueError("Datei-URLs müssen öffentliche HTTPS-Adressen sein")
    addresses = socket.getaddrinfo(parsed.hostname, parsed.port or 443, type=socket.SOCK_STREAM)
    for item in addresses:
        address = ipaddress.ip_address(item[4][0])
        if address.is_private or address.is_loopback or address.is_link_local or address.is_reserved:
            raise ValueError("Private oder lokale Datei-URLs sind nicht erlaubt")
    return parsed


def _decode_image(value: str) -> tuple[bytes, str]:
    mime = ""
    encoded = value
    if value.startswith("data:"):
        header, encoded = value.split(",", 1)
        mime = header[5:].split(";")[0].lower()
    try:
        content = base64.b64decode(encoded, validate=True)
    except (ValueError, TypeError) as exc:
        raise ValueError("Ungültige Base64-Bilddaten") from exc
    if len(content) > MAX_FILE_BYTES:
        raise ValueError("Bild ist größer als 30 MB")
    mime = mime or _detect_image_mime(content)
    if not mime.startswith("image/"):
        raise ValueError("Base64-Daten enthalten kein unterstütztes Bild")
    return content, mime


def _detect_image_mime(content: bytes) -> str:
    if content.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if content.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if content.startswith((b"GIF87a", b"GIF89a")):
        return "image/gif"
    if content.startswith(b"BM"):
        return "image/bmp"
    if content.startswith((b"II*\x00", b"MM\x00*")):
        return "image/tiff"
    if content.startswith(b"RIFF") and content[8:12] == b"WEBP":
        return "image/webp"
    if len(content) > 12 and content[4:8] == b"ftyp" and content[8:12] in {b"heic", b"heix", b"heif", b"mif1"}:
        return "image/heic"
    raise ValueError("Bildformat konnte nicht erkannt werden")


def _download_generation_image(generation_id: str, image_index: int) -> tuple[dict[str, Any], bytes, str]:
    generation = backend().request("GET", f"/generations/{generation_id}")
    images = _result_images(generation)
    if image_index < 0 or image_index >= len(images):
        raise ValueError("Bildindex außerhalb des gültigen Bereichs")
    image = images[image_index]
    with httpx.Client(timeout=60, follow_redirects=True) as client:
        response = client.get(image["download_url"])
        response.raise_for_status()
    mime = response.headers.get("content-type", image.get("mime_type", "image/png")).split(";")[0]
    return image, response.content, mime


def _export_url(download_url: str, output_format: str) -> str:
    parsed = urlsplit(download_url)
    path = parsed.path.rsplit("/content", 1)[0] + "/export"
    query = dict(parse_qsl(parsed.query, keep_blank_values=True))
    query["format"] = output_format
    return urlunsplit((parsed.scheme, parsed.netloc, path, urlencode(query), parsed.fragment))


def _extension(mime: str) -> str:
    return {
        "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp",
        "image/gif": "gif", "image/bmp": "bmp", "image/tiff": "tiff",
        "image/heic": "heic", "image/heif": "heif",
        "video/mp4": "mp4", "video/quicktime": "mov",
    }.get(mime, "bin")


def _result_images(generation: dict[str, Any]) -> list[dict[str, Any]]:
    return [item for item in generation.get("images", []) if item.get("role") == "result"] or generation.get("images", [])


def _public_result(generation: dict[str, Any]) -> dict[str, Any]:
    keys = (
        "id", "parent_id", "kind", "status", "prompt", "final_prompt", "model",
        "aspect_ratio", "resolution", "seed", "parameters", "favorite", "rating",
        "created_at", "started_at", "completed_at", "images", "references",
        "prompt_templates", "error_code", "error_message",
    )
    return {key: generation.get(key) for key in keys}


def _require_confirmation(confirm: bool) -> None:
    if not confirm:
        raise ValueError("Diese Löschaktion erfordert confirm=true nach ausdrücklicher Bestätigung")


if __name__ == "__main__":
    mcp.run(
        transport="streamable-http",
        host="0.0.0.0",
        port=8001,
        streamable_http_path="/mcp",
        json_response=True,
        transport_security=TransportSecuritySettings(
            allowed_hosts=[PUBLIC_HOST, f"{PUBLIC_HOST}:*", "mcp", "mcp:*", "localhost", "localhost:*"],
            allowed_origins=[f"https://{PUBLIC_HOST}", "https://chatgpt.com"],
        ),
    )
