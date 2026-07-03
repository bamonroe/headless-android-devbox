# BAM Store

A private, self-hosted Android app store — a personal F-Droid for distributing the
apps I build to my own Pixel devices.

## Layout

| Path | What |
| --- | --- |
| `client/` | The store app (Kotlin + Jetpack Compose, `com.bam.store`). Browses the catalog, downloads APKs, installs them via `PackageInstaller`. |
| `repo/` | The static repository (`apks/`, `icons/`, and a generated `index.json`) served as static files — live at `http://apps.bam/` over the tailnet. |
| `tools/` | `publish` and `reindex` — Python CLIs that read APK metadata with `aapt2` and (re)generate `index.json`. |

## Publishing an app

```bash
tools/publish path/to/app.apk --changelog "What changed"
```

This extracts the package name, version, icon, and size, copies the APK to
`repo/apks/`, and rebuilds `repo/index.json`. The changelog is saved in a
committed sidecar (`repo/apks/<pkg>-<versionCode>.json`) so it survives a
`tools/reindex`; the APKs, icons, and `index.json` themselves are gitignored
(regenerable payload).

## Serving

The repo is served as static files at **`http://apps.bam/`** over the tailnet via
Caddy (managed with the `caddy` skill; see `repo/Caddyfile.example`). Plain HTTP is
fine because Tailscale encrypts the connection. The client defaults to this URL.

## Building the client

```bash
cd client
./gradlew :app:assembleDebug     # → app/build/outputs/apk/debug/app-debug.apk
./gradlew :app:installDebug      # build + install to the connected device
```

Requires the Android SDK (`ANDROID_HOME`, default `~/Android/Sdk`). To install the
store app the first time, sideload the APK and grant it "Install unknown apps".

See [CLAUDE.md](./CLAUDE.md) for architecture, the `index.json` contract, and the
install-flow details.
