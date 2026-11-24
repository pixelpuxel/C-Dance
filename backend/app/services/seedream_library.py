from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import httpx

from app.core.config import get_settings


class SeedreamLibraryError(RuntimeError):
    pass


@dataclass(frozen=True)
class SeedreamLibraryPage:
    items: list[dict[str, Any]]
    total: int


def _configuration() -> tuple[str, str, float]:
    settings = get_settings()
    base_url = settings.seedream_library_base_url.rstrip("/")
    if base_url and not base_url.endswith("/api/v1"):
        base_url += "/api/v1"
    if not base_url or not settings.seedream_library_api_key:
        raise SeedreamLibraryError("Die Seedream-Online-Bibliothek ist auf diesem Server noch nicht eingerichtet.")
    return base_url, settings.seedream_library_api_key, float(settings.seedream_library_timeout_seconds)


async def list_seedream_images(query: str = "", limit: int = 60, offset: int = 0) -> SeedreamLibraryPage:
    base_url, api_key, timeout = _configuration()
    headers = {"X-API-Key": api_key}
    generations: list[dict[str, Any]] = []
    remote_offset = 0
    remote_total = 1

    try:
        async with httpx.AsyncClient(timeout=timeout, follow_redirects=True) as client:
            while remote_offset < remote_total:
                response = await client.get(
                    f"{base_url}/generations",
                    headers=headers,
                    params={"limit": 100, "offset": remote_offset, "status": "completed"},
                )
                response.raise_for_status()
                payload = response.json()
                page_items = payload.get("items", [])
                remote_total = int(payload.get("total", len(page_items)))
                if not page_items:
                    break
                generations.extend(page_items)
                remote_offset += len(page_items)
                # Keep the library responsive even on very large installations.
                if remote_offset >= 2_000:
                    break
    except (httpx.HTTPError, ValueError, TypeError) as exc:
        raise SeedreamLibraryError("Die Seedream-Online-Bibliothek ist momentan nicht erreichbar.") from exc

    needle = query.casefold().strip()
    items: list[dict[str, Any]] = []
    for generation in generations:
        searchable = " ".join(
            str(generation.get(key) or "") for key in ("prompt", "final_prompt", "model", "created_at")
        ).casefold()
        if needle and needle not in searchable:
            continue
        for image in generation.get("images", []):
            if image.get("role") != "result" or not str(image.get("mime_type", "")).startswith("image/"):
                continue
            items.append(
                {
                    "id": f"{generation.get('id')}:{image.get('id')}",
                    "generation_id": generation.get("id"),
                    "source_image_id": image.get("id"),
                    "prompt": generation.get("prompt") or "",
                    "final_prompt": generation.get("final_prompt") or generation.get("prompt") or "",
                    "created_at": generation.get("created_at"),
                    "image": image,
                }
            )

    return SeedreamLibraryPage(items=items[offset : offset + limit], total=len(items))


async def download_seedream_image(image_id: str) -> tuple[bytes, str, str]:
    base_url, api_key, timeout = _configuration()
    try:
        async with httpx.AsyncClient(timeout=timeout, follow_redirects=True) as client:
            metadata_response = await client.get(f"{base_url}/images/{image_id}", headers={"X-API-Key": api_key})
            metadata_response.raise_for_status()
            metadata = metadata_response.json()
            content_response = await client.get(metadata["download_url"])
            content_response.raise_for_status()
            mime_type = content_response.headers.get("content-type", metadata.get("mime_type", "image/jpeg")).split(";", 1)[0]
            return content_response.content, mime_type, f"seedream-{image_id}"
    except (httpx.HTTPError, KeyError, ValueError, TypeError) as exc:
        raise SeedreamLibraryError("Das Seedream-Bild konnte nicht übernommen werden.") from exc
