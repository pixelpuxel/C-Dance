FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
RUN addgroup --system app && adduser --system --ingroup app app
COPY pyproject.toml server.py ./
RUN pip install --no-cache-dir .
RUN mkdir -p /data && chown app:app /data
USER app
EXPOSE 8001
CMD ["python", "server.py"]
