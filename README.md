# BAM Store

A private, self-hosted Android app store — a personal F-Droid for distributing the
apps I build to my own Pixel devices.

## Layout

| Path | What |
| --- | --- |
| `client/` | The store app (Kotlin + Jetpack Compose, `com.bam.store`). Browses the catalog, downloads APKs, installs them via `PackageInstaller`. |
| `repo/` | The static repository served over HTTPS: `apks/`, `icons/`, and a generated `index.json`. |
| `tools/` | `publish` and `reindex` — Python CLIs that read APK metadata with `aapt2` and (re)generate `index.json`. |

## Publishing an app

```bash
tools/publish path/to/app.apk --changelog "What changed"
```

This extracts the package name, version, icon, and size, copies the APK to
`repo/apks/`, and rebuilds `repo/index.json`. Then serve `repo/` as static files
(see `repo/Caddyfile.example`).

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
