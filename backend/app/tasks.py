import logging
import time
from datetime import UTC, datetime
from urllib.parse import urlparse

import httpx
from billiard.exceptions import SoftTimeLimitExceeded
from sqlalchemy import select
from sqlalchemy.orm import selectinload

from app.celery_app import celery_app
from app.core.config import get_settings
from app.core.security import create_download_token
from app.database import SessionLocal
from app.models import Generation, GenerationImage, GenerationReference, GenerationStatus, ProviderRequest, ProviderResponse
from app.services.apns import send_generation_completed
from app.services.images import prepare_provider_image
from app.services.provider import ArkSeedanceProvider, ProviderError, safe_provider_payload
from app.services.provider_config import provider_api_key
from app.services.storage import get_storage

logger = logging.getLogger(__name__)


@celery_app.task(bind=True, autoretry_for=(), name="cdance.process_generation")
def process_generation(self, generation_id: str) -> None:
    settings = get_settings()
    storage = get_storage()
    with SessionLocal() as db:
        generation = db.scalar(
            select(Generation).where(Generation.id == generation_id).options(
                selectinload(Generation.references).selectinload(GenerationReference.image)
            )
        )
        if not generation or generation.status not in {GenerationStatus.queued, GenerationStatus.processing}:
            return
        generation.status = GenerationStatus.processing
        generation.started_at = generation.started_at or datetime.now(UTC)
        db.commit()
        try:
            api_key, _ = provider_api_key(db, generation.user_id)
            provider = ArkSeedanceProvider(settings, api_key=api_key)
            provider_response = db.scalar(select(ProviderResponse).where(ProviderResponse.generation_id == generation.id))
            result_payload = provider_response.payload if provider_response else None

            if not isinstance(result_payload, dict) or not isinstance(result_payload.get("content", {}).get("video_url") if isinstance(result_payload.get("content"), dict) else None, str):
                task_id = result_payload.get("id") if isinstance(result_payload, dict) else None
                if not isinstance(task_id, str):
                    references = []
                    for reference in generation.references:
                        media = reference.image
                        data = storage.read(media.storage_key)
                        if media.mime_type.startswith(("video/", "audio/")):
                            token = create_download_token(media.id, expires_minutes=60)
                            public_url = f"{settings.public_base_url.rstrip('/')}/api/v1/images/{media.id}/content?token={token}"
                            references.append((data, media.mime_type, public_url))
                        else:
                            prepared, prepared_mime = prepare_provider_image(data)
                            references.append((prepared, prepared_mime, None))
                    payload = provider.build_payload(
                        model=generation.model,
                        prompt=generation.final_prompt,
                        resolution=generation.resolution,
                        aspect_ratio=generation.aspect_ratio,
                        references=references,
                        parameters=generation.parameters or {},
                    )
                    db.add(ProviderRequest(generation_id=generation.id, endpoint=settings.seedance_endpoint, payload=safe_provider_payload(payload)))
                    created = provider.create_task(payload)
                    result_payload = created.payload
                    provider_response = ProviderResponse(generation_id=generation.id, status_code=created.status_code, payload=result_payload)
                    db.add(provider_response)
                    db.commit()
                    task_id = result_payload["id"]

                finished = provider.wait_for_task(task_id)
                result_payload = finished.payload
                provider_response.status_code = finished.status_code
                provider_response.payload = result_payload
                db.commit()

            content = result_payload.get("content")
            video_url = content.get("video_url") if isinstance(content, dict) else None
            data, mime = _download_video(video_url, settings.provider_timeout_seconds)
            extension = "mov" if "quicktime" in mime else "mp4"
            key, byte_size = storage.put(data, extension)
            db.add(GenerationImage(
                user_id=generation.user_id,
                generation_id=generation.id,
                storage_key=key,
                original_filename=f"cdance-{generation.id}.{extension}",
                mime_type=mime,
                width=None,
                height=None,
                byte_size=byte_size,
                role="result",
                provider_url=video_url,
            ))
            generation.seed = result_payload.get("seed") if isinstance(result_payload.get("seed"), int) else generation.seed
            generation.parameters = {
                **(generation.parameters or {}),
                "duration": result_payload.get("duration", (generation.parameters or {}).get("duration", settings.seedance_default_duration)),
                "frames_per_second": result_payload.get("framespersecond"),
                "generate_audio": result_payload.get("generate_audio", (generation.parameters or {}).get("generate_audio", settings.seedance_generate_audio)),
            }
            generation.status = GenerationStatus.completed
            generation.completed_at = datetime.now(UTC)
            db.commit()
            try:
                send_generation_completed(db, generation.id)
            except Exception:
                db.rollback()
                logger.exception("Push notification failed for completed generation %s", generation.id)
        except SoftTimeLimitExceeded:
            _fail_generation(db, generation_id, "provider_deadline_exceeded", "Die Filmgenerierung hat das maximale Zeitlimit überschritten.")
        except ProviderError as exc:
            db.rollback()
            current = db.get(Generation, generation_id)
            if exc.code == "result_download_failed" and current and self.request.retries < 8:
                current.status = GenerationStatus.processing
                current.error_code = "result_download_retrying"
                current.error_message = "Der Film ist fertig und wird erneut vom Anbieter geladen."
                db.commit()
                raise self.retry(exc=exc, countdown=min(30 * (2**self.request.retries), 300), max_retries=8)
            _fail_generation(db, generation_id, exc.code, exc.user_message, exc)
        except Exception:
            db.rollback()
            _fail_generation(db, generation_id, "internal_processing_error", "Der Film konnte nicht verarbeitet oder gespeichert werden.")
            logger.exception("Unhandled video generation failure %s", generation_id)
            raise


def _fail_generation(db, generation_id: str, code: str, message: str, provider_error: ProviderError | None = None) -> None:
    generation = db.get(Generation, generation_id)
    if generation:
        generation.status = GenerationStatus.failed
        generation.error_code = code
        generation.error_message = message
        generation.completed_at = datetime.now(UTC)
        if provider_error and not db.scalar(select(ProviderResponse).where(ProviderResponse.generation_id == generation_id)):
            db.add(ProviderResponse(generation_id=generation_id, status_code=provider_error.status_code, payload=provider_error.payload))
        db.commit()
    logger.error("C-Dance provider failure for generation %s: %s", generation_id, code)


def _download_video(url: str | None, timeout: int) -> tuple[bytes, str]:
    if not isinstance(url, str) or urlparse(url).scheme != "https":
        raise ProviderError("invalid_result_url", "C-Dance hat eine ungültige Videoadresse geliefert.", 502)
    attempt_timeout = httpx.Timeout(connect=20, read=min(300, timeout), write=30, pool=20)
    last_error: Exception | None = None
    for attempt in range(6):
        try:
            with httpx.Client(timeout=attempt_timeout, follow_redirects=True) as client:
                response = client.get(url)
                response.raise_for_status()
            if len(response.content) > 750 * 1024 * 1024:
                raise ProviderError("result_too_large", "Der erzeugte Film überschreitet die Speichergrenze.", 502)
            mime = response.headers.get("content-type", "video/mp4").split(";")[0]
            if mime not in {"video/mp4", "video/quicktime"}:
                mime = "video/mp4"
            return response.content, mime
        except (httpx.ConnectError, httpx.TimeoutException, httpx.HTTPStatusError) as exc:
            last_error = exc
            if isinstance(exc, httpx.HTTPStatusError) and exc.response.status_code < 500:
                break
            if attempt < 5:
                time.sleep(2**attempt)
    raise ProviderError("result_download_failed", "Der fertige Film konnte beim Anbieter noch nicht geladen werden.", 502) from last_error
