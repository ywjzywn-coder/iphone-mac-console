# iPhone Mac Console

Use an old iPhone as a local Mac touchpad, keyboard, and command panel.

## Run

```sh
npm start
```

You can also double-click `start-mac-console.command` in Finder.

Open the printed `http://...:8787` URL on the iPhone, then enter the 6 digit pair code from the Mac terminal.

## Mac Menu Bar App

Build and launch the resident macOS host app:

```sh
./script/build_and_run.sh
```

The app bundle is staged at:

```text
dist/Mac Console Host.app
```

It runs as a menu bar app, starts the local server, shows the current pair code, copies or opens the phone URL, restarts the server, opens Accessibility settings, and can install or remove a LaunchAgent for login startup.

Runtime status is written to:

```text
.runtime/status.json
```

For Android PWA installation, use HTTPS:

```sh
npm run start:https
```

Open the printed `https://...:8788` URL. Android usually requires a trusted HTTPS certificate before it will show a real Install app option. This project generates `certs/localhost-cert.pem`; install and trust that certificate on the phone, or use a trusted HTTPS tunnel.

## Install On Phone

- iPhone/iPad: open the URL in Safari, share, then Add to Home Screen.
- Android: open the URL in Chrome, menu, then Add to Home screen or Install app when available.

The app includes PWA metadata and standalone display settings. iOS can usually launch the home-screen copy without Safari controls over local HTTP. Android may require HTTPS for a true installed PWA; local HTTP still works as a browser shortcut.

Portrait and landscape are both supported. The touchpad stays as the main full-screen surface in both orientations, with controls tucked into the floating drawer.

Enable Default Landscape in Settings or the floating drawer if you mostly use the app sideways. Browsers that support the Screen Orientation API will try to lock landscape; older iOS/Safari builds may only show a rotate hint because they do not allow web apps to force orientation.

Cursor speed is adjustable from Settings or the floating drawer, from `0.30x` to `4x`.

Use the Full Screen button in the header or the floating drawer to request browser fullscreen. On iPhone Safari, where web pages cannot always force true fullscreen, the app falls back to an immersive mode that keeps the touchpad stretched to the visible screen and nudges the browser chrome out of the way.

## Gestures

- One finger: move cursor.
- One finger tap: left click.
- One finger double tap: double click.
- One finger long press then move: drag windows, files, sliders, or selected text.
- Two finger tap: right click.
- Two finger drag: scroll.
- Two finger horizontal swipe: browser/app back or forward with `Command` + `[` / `]`.
- Two finger pinch: zoom in or out using `Command` + `+` / `-`.
- Three finger swipe up: Mission Control, using the native Mission Control app with `Control` + `Up` as a fallback.
- Three finger swipe down: App Expose.
- Three or four finger swipe left or right: switch desktops.
- Floating `...` drawer: fullscreen, pointer speed, Default Landscape, and Drag Lock.
- Keyboard, command, and settings panels stay available behind the bottom tabs while the main pad stays large.

Unsupported or approximate:

- Force Click / pressure sensitivity: phone browsers do not expose Mac trackpad pressure.
- True inertial scrolling: the app can send scroll deltas, but cannot perfectly emulate Apple trackpad hardware momentum.
- Launchpad pinch: macOS does not expose a stable public "become a trackpad" API, and this Mac does not provide a Launchpad app that can be opened directly. Mapping it to a function key would depend on the user's keyboard settings.
- Show Desktop spread: phone browsers do not expose the exact thumb-plus-fingers gesture shape reliably, so it is better as a command button than a default gesture.
- Rotate gesture: not useful system-wide and not exposed consistently across iOS/Android browsers.
- Three finger drag as a distinct Mac setting: Safari/Chrome only report touch points to the web page, not the macOS accessibility setting. The app uses one-finger long-press drag instead.
- Real Apple Trackpad device identity: macOS does not expose a public API for a web app to become a hardware trackpad.

## macOS Permission

If the web UI connects but the Mac does not move or type, allow the terminal app that runs this server in:

System Settings > Privacy & Security > Accessibility

Then restart the server.

## Notes

- The server listens on the local network.
- Pairing uses a fresh code and session token each run unless `PAIR_CODE` is set.
- Camera and microphone are intentionally left to DroidCam/Camo/OBS for now. This tool focuses on control.
