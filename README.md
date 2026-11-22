# C-Dance

C-Dance ist eine eigenständige Film-App für Dreamina Seedance. Sie teilt das bewährte Bedienkonzept der Schwester-App Seedream, verwendet aber getrennte Bundle-IDs, App-Group, lokale Speicher, Datenbank, Backend-Domain und App-Store-Einträge.

Enthalten sind:

- native SwiftUI-App für iPhone und iPad samt Watch-App, Share Extension und Notification Service,
- Standalone-Modus mit im iOS-Schlüsselbund gespeichertem BytePlus-Ark-Key,
- selbst hostbares FastAPI-/Celery-Backend mit PostgreSQL, Redis und dauerhaftem Videospeicher,
- Web-Oberfläche und separater MCP-Server,
- Docker-Compose- und Reverse-Proxy-Konfiguration für `cdance.schreiber.info`.

## Seedance-Anbindung

Die Implementierung verwendet die asynchrone ModelArk Content Generation API:

- Aufgabe anlegen: `POST /api/v3/contents/generations/tasks`
- Status und Ergebnis abfragen: `GET /api/v3/contents/generations/tasks/{id}`
- Standardmodell: `dreamina-seedance-2-5-260628`
- Flash-Modell: `dreamina-seedance-2-5-flash-261115`

Seedance 2.5 unterstützt 4–30 Sekunden, 480p bis 4K, Tonerzeugung sowie Bild-, Video- und Audioreferenzen. Ergebnis-URLs des Anbieters werden sofort heruntergeladen und dauerhaft gespeichert. Referenzvideos werden dem Anbieter als kurzlebige signierte HTTPS-URLs bereitgestellt.

## Lokaler Start

```bash
cp .env.example .env
docker compose up --build
```

Die Platzhalter in `.env` müssen durch eigene zufällige Geheimnisse ersetzt werden. API-Schlüssel, Apple-Schlüssel und Passwörter gehören niemals ins Repository.

Backend-Tests:

```bash
cd backend
uv sync --dev
uv run pytest
```

iOS-Build:

```bash
xcodebuild -project ios/CDance.xcodeproj -scheme CDance \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  CODE_SIGNING_ALLOWED=NO build
```

## Betriebsarten

Neue Installationen starten im Standalone-Modus. Der Ark-API-Key wird ausschließlich im iOS-Schlüsselbund gespeichert; Verlauf, Prompts, Referenzen und heruntergeladene Filme bleiben im App-Speicher. Die eigentliche Generierung benötigt eine Internetverbindung.

Im Servermodus laufen lange Filmaufträge unabhängig vom App-Lebenszyklus in der Warteschlange weiter. Backend, Daten und Nutzerkonten sind vollständig von Seedream getrennt.

Öffentlicher Kontakt: `cdance@post.schreiber.info`
