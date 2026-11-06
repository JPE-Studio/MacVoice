# MacVoice

Menüleisten-App: Sprache → Text (in das fokussierte Textfeld) oder Sprache → Tool-Call.
Ersetzt WhisperFlow. Läuft komplett lokal über die Cactus-Engine (Whistle + Needle 3), kein Python, keine Cloud.

## Benutzung

- **Rechte ⌘-Taste** (oder F5): Aufnahme starten/stoppen → Transkript wird ins fokussierte Textfeld eingefügt.
  Ist kein Textfeld fokussiert, wird das Transkript als Befehl interpretiert (Tool-Call).
- **F6**: Aufnahme → direkt Tool-Call.
- Menüleisten-Icon: 🎙 bereit, ▁▃▅▇ Wave während der Aufnahme, ✓ nach erfolgreichem Einfügen.
- Erste Nutzung: macOS fragt nach **Bedienungshilfen** (für Einfügen + Textfeld-Erkennung) und **Mikrofon**-Berechtigung — beides erlauben.

## Tool-Befehle (Beispiele)

`set volume to 30` · `open Safari` · `quit Mail` · `open wikipedia.org` · `lock the screen` ·
`take a screenshot` · `say hello` · `put the Mac to sleep`

## Bauen & Starten

```bash
cd ~/Documents/code/MacVoice
./make-app.sh        # baut build/MacVoice.app
open build/MacVoice.app
```

## Struktur

- `Sources/MacVoice/main.swift` — die ganze App (Engine, Recorder, Menüleiste, Hotkeys, Tool-Ausführung)
- `Sources/Ccactus/` — Swift-Bindung zur C-API (`macos-arm64/cactus.h`)
- `macos-arm64/` — vorkompilierte Engine (`libcactus.a`) via `cactus download macos-arm64`
- `Tests/engine_test.swift` — Standalone-Check der C-Bindings gegen die echte Engine
- `tools.json` — Tool-Definitionen (Referenz; die App hat sie eingebettet)

## Voraussetzungen

- Modelle unter `~/whistle.cact` und `~/needle3.cact` (via `cactus download whistle` / `cactus download needle3`)

## Anpassen

- Tools: Konstante `toolsJSON` + `executeTool()` in `main.swift`
- Hotkeys: `installHotkeys()` (Carbon KeyCodes)
