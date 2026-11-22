from celery import Celery

from app.core.config import get_settings

settings = get_settings()
celery_app = Celery("cdance", broker=settings.redis_url, backend=settings.redis_url, include=["app.tasks"])
celery_app.conf.update(
    task_track_started=True,
    task_acks_late=True,
    worker_prefetch_multiplier=1,
    task_reject_on_worker_lost=True,
    result_expires=3600,
    broker_connection_retry_on_startup=True,
    # A provider can keep making tiny amounts of progress and therefore never
    # hit an httpx inactivity timeout. These limits are a hard safety net for
    # the complete generation task, including result download and persistence.
    task_soft_time_limit=settings.provider_timeout_seconds + 180,
    task_time_limit=settings.provider_timeout_seconds + 210,
)

