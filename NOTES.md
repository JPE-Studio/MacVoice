# MacVoice — Session-Notizen & Entscheidungsbuch

Produktvision: Sprachassistent für einen **8-GB-MacBook**, komplett lokal, mit den besten und
kleinsten Modellen. Steuert den Mac, gibt gesprochene Antworten, hat ein Gedächtnis und eine
`soul.md`. Ersatz für WhisperFlow — und Sprachfrontend für einen persönlichen Agenten.

## Architektur (Stand v1.3.0)

| Baustein | Wahl | Warum |
|---|---|---|
| STT | **Whistle** (16.9 MB, Cactus) | 7 Sprachen, 11 ms TTFT, on-device, streaming-fähig |
| Tool-Calling | **Needle 3** (35 MB, Cactus) | versteht auch deutsche Befehle, 13 Tools |
| Engine | **libcactus.a** statisch gelinkt | kein Python, kein Server, ~250 MB RAM gesamt |
| App | Swift Menüleiste, LSUIElement | Hold-to-Talk: rechte ⌘ = Diktat, ⌘+⇧ = Tool-Call, F5/F6 optional |
| Denken | **noch offen** — 4 Use Cases brauchen keins | Phase 2: nanobot (Agent-Gehirn via HTTP) oder llama.cpp + gemma-4-e2b GGUF |
| TTS (vorerst) | macOS `say` | Phase 3: KittenTTS nativ (kitten-tts-2-cpp, 492 MB, Deutsch) |

Verteilung: `build/MacVoice.app` ist **autark** (Modelle gebundelt, 51 MB), Update-Check gegen
GitHub `releases/latest`. Repo: `JPE-Studio/MacVoice` (öffentlich, alles andere privat).

## Die 4 Use Cases (v1.3.0, alle ohne neues Modell)

1. „Wo kann ich den Batteriestatus sehen?" → `open_settings_pane` (x-apple.systempreferences URLs, 20+ Panes)
2. „Welchen Termin habe ich heute?" → `get_todays_events` (AppleScript Calendar + `say`-Antwort + Calendar öffnet)
3. „Wo finde ich die Adresse?" → `find_on_page` (browser JS `window.find()`, scrollt + markiert)
4. „Ich muss noch Milch kaufen" → `add_reminder` (Reminders-App, Liste „Einkauf", spricht Bestätigung)

Gedächtnis: `remember`-Tool → `~/Library/Application Support/MacVoice/memory.md`.
Persönlichkeit: `soul.md` im selben Ordner — später System-Prompt des Denk-Modells.

## Debugging-Klassiker dieser Session (nicht wieder reinfallen)

- **`cactus_complete("", pcm)` schlägt fehl** — Audio-Pfad verlangt `NULL` als Input, leerer String gibt -1.
- **Carbon-Hotkeys auto-repeaten beim Halten** (Press/Release-Sturm, 0 Samples) → CGEventTap nutzen,
  Auto-Repeat filtern, Start/Stop async dispatchen.
- **`NX_DEVICERCMDKEYMASK = 0x10`** (nicht 0x08, nicht 0x200) — Werte gegen
  `IOKit.framework/Headers/hidsystem/IOLLEvent.h` verifizieren, nie raten.
- **cactus_load: 0 = Erfolg**, nonzero = Fehler. Nicht invertieren.
- **Ad-hoc-Signaturen ändern sich bei jedem Build** → TCC hält jede Version für eine neue App →
  ewige Berechtigungs-Prompts. Fix: stabiles selbst-signiertes Zertifikat (`create-signing-cert.sh`,
  Identität „MacVoiceDev"). Achtung: `grep -o '"MacVoiceDev"'` liefert Quotes mit!
- **Background-Launches bekommen keinen Fokus** → nach `open -a` immer per AppleScript aktivieren.
- **Electron-Apps (Beeper) verstecken Textfelder vor der AX-API** → Diktat fügt IMMER per Paste ein
  (Cmd+V-Simulation), nie auf AX-Erkennung vertrauen.
- **Gesprochene URLs**: „Google Punkt kommen" → Needle wählt evtl. `open_app("Google Punkt kommen")`.
  Fixes: URL-Normalisierung (punkt→., kommen→com, „ com"→„.com"), Domain-Erkennung + open_app→open_url-Fallback.
- **Deutsche App-Namen**: App-Namen sind auf macOS immer englisch → Alias-Tabelle
  (Terminalfenster→Terminal, Notizen→Notes, …).
- **Calendar AppleScript**: Property heißt `start date`, NICHT `start time`.
- **Delete-Taste ohne Hold**: Event-Tap darf Auto-Repeats nur für F5/F6 schlucken, alle anderen Keys durchlassen.
- **Erste Mikrofon-Aufnahme dauert ~3 s** (CoreAudio-Cold-Start) → Warmup beim App-Start.

## Streaming-Live-Transkription

`cactus_stream_transcribe_process`: Chunks alle 0,5 s füttern → inkrementelle Partials
(`text` = neu committet, `pending` = läuft) → Live-Ticker im Panel. `stream_stop` flusht.
Ergebnis ist identisch zur Batch-Transkription → Diktat nutzt den Stream-Text direkt,
kein zweiter Durchlauf. Recorder braucht NSLock (Audio-Thread schreibt, UI liest).

## Verwaltung & Befehle

```bash
cd ~/Documents/code/MacVoice
./make-app.sh                 # baut + signiert + bündelt Modelle aus ~/
./make-release.sh [minor]     # Version-Bump, Build, Zip, Commit, Tag, Push, GitHub-Release (Notes = CHANGELOG.md-Abschnitt)
tail -f /tmp/macvoice.log     # Diagnose-Log (startRecording, Transkripte, Tool-Results, AS-Fehler)
```
- Test ohne Stimme: Menüpunkt „Test tool call (calendar)".
- Modelle neu laden: `cactus download whistle` / `cactus download needle3` (in `~`).
- Berechtigungen: Bedienungshilfen (Paste + Event-Tap), Mikrofon, Automation (Calendar/Reminders),
  Brave: „JavaScript von Apple Events erlauben" (Ansicht → Entwickler).

## Roadmap (offene Stufen)

1. **Phase 2 — Denken**: nanobot als lokaler Agent-Backend (OpenAI-kompatible API, Gedächtnis/Dream,
   Web-Suche, Cron) — MacVoice bekommt ein `ask_nanobot`-Tool. Alternative: llama.cpp + gemma-4-e2b
   (~2 GB). Beide fiten in 8 GB RAM, nanobot braucht Python 3.11 (brew).
   Später Richtung 2: MacVoice-Tools als MCP-Server für nanobot.
2. **Phase 3 — KittenTTS**: `kitten-tts-2-cpp` (llama.cpp-Fork) statisch linken, 115 Stimmen,
   Deutsch, Voice-Cloning — ersetzt `say`. +492 MB App-Größe.
3. **laya** (Decision-Engine, 33 ms): als Auto-Router „Diktat oder Befehl?" → eine Taste statt zwei;
   kalibriertes Sicherheits-Gate vor destruktiven Tools. Native Integration via ONNX-Export.
4. **Cactus-Ökosystem beobachten**: Gemma-4-Spiegel mit `cactus`-Tag auf HF — ein Chat-`.cact`
   würde Phase 2 ohne zweiten Engine erledigen.

## Offene Punkte / bekannte Grenzen

- Calendar/Reminders-Automation beim ersten Nutzen erlauben (einmaliger Prompt).
- Use Case 3 nur wenn Browser-Fenster vorne ist; Firefox nicht unterstützt (kein JS via AppleScript).
- Needle 3 ist auf Englisch trainiert — deutsche Formulierungen funktionieren meistens
  („Kannst du bitte Figma öffnen?" ✓), sind aber Glückssache; Konfidenz oft < 0.3.
- Desktop-App `say` klingt robotisch (Phase 3 behebt das).
- 8-GB-Budget: Kern ~250 MB. Phase 2 (+1–2 GB) und Phase 3 (+0.5 GB) passen nebeneinander,
  aber nicht gleichzeitig mit vielen großen Apps offen.
