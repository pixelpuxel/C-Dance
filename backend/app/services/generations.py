import json
from collections.abc import Sequence

from fastapi import HTTPException, UploadFile
from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from app.core.config import get_settings
from app.models import (
    Generation,
    GenerationImage,
    GenerationKind,
    GenerationPromptTemplate,
    GenerationReference,
    PromptTemplate,
    User,
)
from app.services.images import inspect_image
from app.services.storage import get_storage


LEGACY_MODEL_ROLES = {
    "dreamina-seedance-2-5-260628": "2.5",
    "dreamina-seedance-2-5-flash-261115": "2.5-flash",
    "dreamina-seedance-2-0-260128": "2.0",
    "dreamina-seedance-2-0-fast-260128": "2.0-fast",
}


def normalize_model(model: str | None, settings) -> str:
    chosen = model or settings.seedance_model
    role = LEGACY_MODEL_ROLES.get(chosen)
    if role == "2.5":
        return settings.seedance_model
    if role == "2.5-flash":
        return settings.seedance_flash_model
    if role == "2.0":
        return settings.seedance_20_model
    if role == "2.0-fast":
        return settings.seedance_fast_model
    return chosen


def parse_string_list(value: str | None) -> list[str]:
    if not value:
        return []
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as exc:
        raise HTTPException(422, detail={"code": "invalid_list", "message": "Listen müssen als JSON-Array übergeben werden."}) from exc
    if not isinstance(parsed, list) or not all(isinstance(item, str) for item in parsed):
        raise HTTPException(422, detail={"code": "invalid_list", "message": "Ungültige Liste."})
    return parsed


def parse_parameters(value: str | None) -> dict:
    if not value:
        return {}
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as exc:
        raise HTTPException(422, detail={"code": "invalid_parameters", "message": "Parameter müssen ein JSON-Objekt sein."}) from exc
    if not isinstance(parsed, dict):
        raise HTTPException(422, detail={"code": "invalid_parameters", "message": "Parameter müssen ein JSON-Objekt sein."})
    return parsed


async def create_generation(
    db: Session,
    user: User,
    *,
    prompt: str,
    final_prompt: str | None,
    template_ids: Sequence[str],
    image_ids: Sequence[str],
    uploads: Sequence[UploadFile],
    model: str | None,
    aspect_ratio: str,
    resolution: str | None,
    parent_id: str | None,
    kind: GenerationKind,
    parameters: dict,
) -> Generation:
    settings = get_settings()
    allowed_models = {
        settings.seedance_model,
        settings.seedance_flash_model,
        settings.seedance_20_model,
        settings.seedance_fast_model,
    }
    chosen_model = normalize_model(model, settings)
    if chosen_model not in allowed_models:
        raise HTTPException(422, detail={"code": "unsupported_model", "message": "Das ausgewählte Modell ist nicht konfiguriert."})
    chosen_resolution = resolution or settings.seedance_default_resolution
    if chosen_resolution not in settings.configured_sizes and not _valid_pixel_size(chosen_resolution):
        raise HTTPException(422, detail={"code": "unsupported_resolution", "message": "Die ausgewählte Auflösung ist nicht konfiguriert."})
    if aspect_ratio not in {"auto", "1:1", "4:3", "3:4", "16:9", "9:16", "3:2", "2:3", "21:9"}:
        raise HTTPException(422, detail={"code": "unsupported_aspect_ratio", "message": "Nicht unterstütztes Seitenverhältnis."})
    parent = None
    if parent_id:
        parent = db.scalar(select(Generation).where(Generation.id == parent_id, Generation.user_id == user.id))
        if not parent:
            raise HTTPException(404, detail={"code": "parent_not_found", "message": "Ausgangsgeneration nicht gefunden."})

    templates = []
    for template_id in template_ids:
        template = db.scalar(select(PromptTemplate).where(PromptTemplate.id == template_id, PromptTemplate.user_id == user.id))
        if not template:
            raise HTTPException(404, detail={"code": "template_not_found", "message": "Ein Prompt-Baustein wurde nicht gefunden."})
        templates.append(template)
    composed = "\n\n".join([template.text.strip() for template in templates] + ([prompt.strip()] if prompt.strip() else []))
    effective_prompt = (final_prompt or composed).strip()
    if not effective_prompt:
        raise HTTPException(422, detail={"code": "prompt_required", "message": "Bitte einen Prompt eingeben oder Prompt-Bausteine auswählen."})

    generation = Generation(
        user_id=user.id,
        parent_id=parent.id if parent else None,
        kind=kind,
        prompt=prompt.strip(),
        final_prompt=effective_prompt,
        model=chosen_model,
        aspect_ratio=aspect_ratio,
        resolution=chosen_resolution,
        parameters=parameters,
    )
    db.add(generation)
    db.flush()
    for position, template in enumerate(templates):
        db.add(
            GenerationPromptTemplate(
                generation_id=generation.id,
                template_id=template.id,
                position=position,
                name_snapshot=template.name,
                text_snapshot=template.text,
            )
        )

    reference_images: list[tuple[GenerationImage, str]] = []
    for image_id in image_ids:
        image = db.scalar(select(GenerationImage).where(GenerationImage.id == image_id, GenerationImage.user_id == user.id))
        if not image:
            raise HTTPException(404, detail={"code": "image_not_found", "message": "Ein Referenzbild wurde nicht gefunden."})
        reference_images.append((image, "reference"))
    for upload in uploads:
        data = await upload.read(settings.max_upload_bytes + 1)
        if len(data) > settings.max_upload_bytes:
            raise HTTPException(413, detail={"code": "file_too_large", "message": "Eine Referenz überschreitet die Upload-Grenze."})
        content_type = (upload.content_type or "").lower()
        is_video = content_type in {"video/mp4", "video/quicktime"}
        is_audio = content_type in {"audio/mpeg", "audio/mp3", "audio/wav", "audio/x-wav"}
        if is_video:
            extension = "mov" if upload.content_type == "video/quicktime" else "mp4"
            mime_type = upload.content_type or "video/mp4"
            width = height = None
        elif is_audio:
            extension = "wav" if "wav" in content_type else "mp3"
            mime_type = "audio/wav" if extension == "wav" else "audio/mpeg"
            width = height = None
        else:
            if len(data) > 30 * 1024 * 1024:
                raise HTTPException(413, detail={"code": "image_too_large", "message": "Ein Referenzbild darf höchstens 30 MB groß sein."})
            try:
                info = inspect_image(data, upload.content_type)
            except ValueError as exc:
                raise HTTPException(415, detail={"code": "invalid_media", "message": str(exc)}) from exc
            extension, mime_type, width, height = info.extension, info.mime_type, info.width, info.height
        key, size = get_storage().put(data, extension)
        image = GenerationImage(
            user_id=user.id,
            generation_id=generation.id,
            storage_key=key,
            original_filename=(upload.filename or "upload")[:255],
            mime_type=mime_type,
            width=width,
            height=height,
            byte_size=size,
            role="reference",
        )
        db.add(image)
        db.flush()
        reference_images.append((image, "reference"))
    max_references = 30 if chosen_model == settings.seedance_model else 10
    if len(reference_images) > max_references:
        raise HTTPException(422, detail={"code": "too_many_references", "message": f"Dieses Modell unterstützt höchstens {max_references} Referenzbilder."})
    for position, (image, purpose) in enumerate(reference_images):
        db.add(GenerationReference(generation_id=generation.id, image_id=image.id, position=position, purpose=purpose))
    db.commit()
    return load_generation(db, generation.id, user.id)


def clone_generation(db: Session, user: User, source: Generation, kind: GenerationKind) -> Generation:
    settings = get_settings()
    clone = Generation(
        user_id=user.id,
        parent_id=source.id,
        kind=kind,
        prompt=source.prompt,
        final_prompt=source.final_prompt,
        model=normalize_model(source.model, settings),
        aspect_ratio=source.aspect_ratio,
        resolution=source.resolution,
        seed=source.seed,
        parameters=dict(source.parameters or {}),
    )
    db.add(clone)
    db.flush()
    for link in source.template_links:
        db.add(GenerationPromptTemplate(generation_id=clone.id, template_id=link.template_id, position=link.position, name_snapshot=link.name_snapshot, text_snapshot=link.text_snapshot))
    references = [(reference.image_id, reference.purpose) for reference in source.references]
    if kind == GenerationKind.variation:
        result = next((image for image in source.images if image.role == "result"), None)
        if result:
            max_references = 30 if clone.model == settings.seedance_model else 10
            references = [(result.id, "variation_source")] + [item for item in references if item[0] != result.id]
            references = references[:max_references]
    for position, (image_id, purpose) in enumerate(references):
        db.add(GenerationReference(generation_id=clone.id, image_id=image_id, position=position, purpose=purpose))
    db.commit()
    return load_generation(db, clone.id, user.id)


def load_generation(db: Session, generation_id: str, user_id: str) -> Generation:
    generation = db.scalar(
        select(Generation)
        .where(Generation.id == generation_id, Generation.user_id == user_id)
        .options(
            selectinload(Generation.images),
            selectinload(Generation.references).selectinload(GenerationReference.image),
            selectinload(Generation.template_links),
        )
    )
    if not generation:
        raise HTTPException(404, detail={"code": "generation_not_found", "message": "Generation nicht gefunden."})
    return generation


def _valid_pixel_size(value: str) -> bool:
    return value in {"480p", "720p", "1080p", "2k", "4k"}
