/// <reference types="vite/client" />

const supportEmail = import.meta.env.VITE_SUPPORT_EMAIL?.trim() ?? '';

function ContactLink() {
  if (!supportEmail) return null;
  return <a href={`mailto:${supportEmail}`}>{supportEmail}</a>;
}

export function PublicInfoPage({ page }: { page: 'privacy' | 'support' }) {
  const privacy = page === 'privacy';

  return (
    <main className="public-page">
      <a className="public-brand" href="/" aria-label="C-Dance öffnen">
        <span className="logo" aria-hidden="true">✦</span>
        <strong>C-Dance</strong>
      </a>

      <article className="panel public-card">
        <p className="public-kicker">C-Dance für iPhone und Apple Watch</p>
        <h1>{privacy ? 'Datenschutz' : 'Support'}</h1>

        {privacy ? (
          <>
            <p>Stand: 7. Oktober 2026</p>
            <h2>Überblick</h2>
            <p>C-Dance enthält keine Werbung und kein Nutzer-Tracking. Die App kann wahlweise eigenständig mit einem vom Nutzer bereitgestellten BytePlus-Ark-Zugang oder mit einem selbst betriebenen C-Dance-Server verwendet werden.</p>

            <h2>Standalone-Modus</h2>
            <p>API-Schlüssel werden im iOS-Schlüsselbund gespeichert. Prompts, Einstellungen, Referenzbilder und der Verlauf werden auf dem Gerät abgelegt. Für eine Filmgenerierung übermittelt die App die ausgewählten Referenzmedien, den Prompt und die technischen Einstellungen direkt an BytePlus Ark. Für diese Verarbeitung gelten zusätzlich die Datenschutz- und Aufbewahrungsbestimmungen von BytePlus.</p>

            <h2>Optionaler Servermodus</h2>
            <p>Im Servermodus werden Anmeldung, Prompts, Referenzbilder, Generierungsaufträge und Ergebnisse an den vom Nutzer eingetragenen Server übertragen. Für Betrieb, Sicherheit und Löschung dieser Daten ist der Betreiber des jeweiligen Servers verantwortlich.</p>

            <h2>Fotos, Kamera, Mitteilungen und Apple Watch</h2>
            <p>Auf Fotos und Kamera greift die App nur nach einer entsprechenden Auswahl oder Freigabe zu. Ergebnisse werden nur bei aktivierter Speicherung in die Fotomediathek geschrieben. Mitteilungen können über fertige Aufträge informieren. Zur Anzeige auf einer gekoppelten Apple Watch werden verkleinerte Vorschaubilder über Apples Watch-Verbindung übertragen.</p>

            <h2>Löschen und Kontakt</h2>
            <p>Lokale Verläufe und Bilder lassen sich in der App löschen. Im Servermodus wird ein dort gelöschter Verlaufseintrag zugleich auf dem verbundenen Server entfernt. Fragen zum Datenschutz können an <ContactLink /> gerichtet werden.</p>
          </>
        ) : (
          <>
            <p>Hier findest du Hilfe für Einrichtung und Betrieb der App.</p>
            <h2>Standalone einrichten</h2>
            <ol>
              <li>Öffne in der App die Einstellungen.</li>
              <li>Wähle „Standalone“.</li>
              <li>Trage deinen BytePlus-Ark-API-Schlüssel ein. Er wird im iOS-Schlüsselbund gespeichert.</li>
            </ol>

            <h2>Eigener Server</h2>
            <p>Wähle in den Einstellungen den Servermodus und trage die HTTPS-Adresse deines C-Dance-Servers ein. Anschließend meldest du dich mit dem auf diesem Server angelegten Konto an.</p>

            <h2>Wenn eine Generierung nicht fertig wird</h2>
            <p>Prüfe die Internetverbindung sowie API-Schlüssel beziehungsweise Serverzugang. Laufende Aufträge erscheinen im Verlauf. Im Servermodus werden sie auch weiterverarbeitet, wenn die App geschlossen ist.</p>

            <h2>Kontakt</h2>
            <p>Bitte beschreibe das Problem, die verwendete App-Version und die Schritte, mit denen es auftritt. Screenshots helfen bei Darstellungsfehlern. Kontakt: <ContactLink /></p>
          </>
        )}

        <nav className="public-links" aria-label="Weitere Informationen">
          <a href="/support">Support</a>
          <a href="/datenschutz">Datenschutz</a>
          <a href="/">Web-App</a>
        </nav>
      </article>
    </main>
  );
}
