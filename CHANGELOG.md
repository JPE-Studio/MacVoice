# Changelog

## v1.3.0
- Use case 1 — settings navigation: `open_settings_pane` opens the right System Settings pane ("wo sehe ich den Batteriestatus?" → Battery), 20+ panes with German aliases
- Use case 2 — calendar: `get_todays_events` reads today's events, opens Calendar and speaks the answer
- Use case 3 — page search: `find_on_page` scrolls to and highlights text in the frontmost browser (Safari/Brave/Chrome/Arc/Edge; needs "Allow JavaScript from Apple Events" once)
- Use case 4 — shopping list: `add_reminder` adds items to a Reminders list (creates "Einkauf" if missing), speaks the confirmation
- Memory: `remember` tool appends to `~/Library/Application Support/MacVoice/memory.md`
- `soul.md` — personality file, created on first launch
- All four use cases run on-device with the existing models — no new model, still ~250 MB RAM (fits 8 GB Macs)

## v1.2.1
- Fixed tool calling: an empty input string broke the audio tool-call path (`cactus_complete` requires `NULL`)
- `open_app` now activates the target app — background launches no longer open without focus
- Visible tool-call feedback: the floating panel shows the result for 2.5 s
- German app name aliases (Terminalfenster → Terminal, Notizen → Notes, Vorschau → Preview, …)
- Tool description now tells the model that macOS app names are always English
- Debug menu item "Test tool call (open Figma)" to test tool execution without voice
- Empty command outputs are logged as "ok"

## v1.2.0
- English UI throughout
- Language preselection in settings (default: automatic; en/de/fr/es/it/nl/pl) for dictation and tool calling, applied live
- Update feedback: dialogs for "up to date", "check failed" and "update available"
- About page with version, credits and GitHub link
- GitHub update check: automatic every 24 h + manual "Check for updates"

## v1.1.0
- Configurable hold-to-talk keys via settings menu (dictation: right ⌘ / right ⌥ / F5; tool call: ⌘+⇧ / F6 / right ⌥)
- ⌘+⇧ tool-call preset with cancel guard (joining another key, e.g. ⌘⇧4, aborts silently)
- Red dot menu-bar indicator while recording (waveform stays in the floating panel)
- GitHub update system + `make-release.sh`
- Models bundled inside the app — self-contained .app (51 MB), no Python, no downloads
- App icon
- Stable self-signed build identity so macOS permissions survive rebuilds

## v1.0.0
- Initial release: menu bar hold-to-talk dictation (Whistle) + tool calling (Needle 3), fully on-device
- Paste into the focused text field (works in Electron apps like Beeper)
- Floating waveform panel with live mic level
- Tools: set_volume, open_app, quit_app, open_url, lock_screen, sleep_mac, take_screenshot, say_text
