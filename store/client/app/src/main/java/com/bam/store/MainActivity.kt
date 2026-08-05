package com.bam.store

import android.content.pm.PackageManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.platform.LocalContext
import coil.compose.AsyncImage
import coil.request.ImageRequest
import com.bam.store.data.Catalog
import com.bam.store.data.CatalogApp
import com.bam.store.data.RepoClient
import com.bam.store.data.Settings
import com.bam.store.install.ApkInstaller
import com.bam.store.install.InstallEvent
import com.bam.store.install.InstallEvents
import com.bam.store.ui.BamStoreTheme
import java.io.FileInputStream
import java.security.MessageDigest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Single-activity host; the whole UI is the Compose [StoreScreen]. */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { BamStoreTheme { StoreScreen() } }
    }
}

/**
 * The catalog screen and all of its state. Fetches the catalog via [RepoClient],
 * cross-references each app against [android.content.pm.PackageManager] to derive
 * Install / Update / Installed state, and orchestrates download + install through
 * [ApkInstaller]. Terminal install results arrive asynchronously on [InstallEvents]
 * (collected below) since the OS confirm dialog happens out of process.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StoreScreen() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val settings = remember { Settings(context) }
    val repo = remember { RepoClient(settings) }
    val snackbar = remember { SnackbarHostState() }

    var catalog by remember { mutableStateOf<Catalog?>(null) }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    // packageName -> installed package metadata (absent = not installed)
    val installed = remember { mutableStateMapOf<String, InstalledApp>() }
    // packageName -> download progress (0f..1f) while an install is in flight
    val progress = remember { mutableStateMapOf<String, Float>() }

    suspend fun refreshInstalled(apps: List<CatalogApp>) {
        val found = withContext(Dispatchers.IO) {
            apps.mapNotNull { app ->
                val info = try {
                    context.packageManager.getPackageInfo(app.packageName, 0)
                } catch (e: PackageManager.NameNotFoundException) {
                    null
                }
                val sourceDir = info?.applicationInfo?.sourceDir
                if (info != null && sourceDir != null) {
                    app.packageName to InstalledApp(
                        versionCode = info.longVersionCode,
                        sha256 = sha256File(sourceDir),
                    )
                } else {
                    null
                }
            }.toMap()
        }
        installed.clear()
        installed.putAll(found)
    }

    fun refresh() {
        scope.launch {
            loading = true; error = null
            try {
                val c = repo.fetchCatalog()
                catalog = c
                refreshInstalled(c.apps)
            } catch (e: Exception) {
                error = e.message ?: "failed to load catalog"
            } finally {
                loading = false
            }
        }
    }

    fun installApp(app: CatalogApp) {
        scope.launch {
            progress[app.packageName] = 0f
            try {
                val apk = repo.downloadApk(app, context.cacheDir) { f ->
                    progress[app.packageName] = if (f < 0f) 0f else f
                }
                ApkInstaller.install(context, apk, app.packageName)
                // Terminal result arrives via InstallEvents; keep the row busy until then.
            } catch (e: Exception) {
                progress.remove(app.packageName)
                snackbar.showSnackbar("${app.label}: ${e.message}")
            }
        }
    }

    LaunchedEffect(Unit) { refresh() }

    LaunchedEffect(Unit) {
        InstallEvents.events.collect { ev ->
            progress.remove(ev.packageName)
            catalog?.let { refreshInstalled(it.apps) }
            when (ev) {
                is InstallEvent.Success -> snackbar.showSnackbar("Installed")
                is InstallEvent.Failure -> snackbar.showSnackbar(ev.message)
            }
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(catalog?.name ?: "BAM Store") },
                actions = {
                    IconButton(onClick = { refresh() }) {
                        Icon(Icons.Filled.Refresh, contentDescription = "Refresh")
                    }
                },
            )
        },
        snackbarHost = { SnackbarHost(snackbar) },
    ) { pad ->
        Box(Modifier.fillMaxSize().padding(pad)) {
            when {
                loading && catalog == null ->
                    CircularProgressIndicator(Modifier.align(Alignment.Center))
                error != null && catalog == null ->
                    Text(
                        "Couldn't reach ${settings.baseUrl}\n$error",
                        Modifier.align(Alignment.Center).padding(24.dp),
                    )
                else -> LazyColumn(Modifier.fillMaxSize()) {
                    items(catalog?.apps ?: emptyList(), key = { it.packageName }) { app ->
                        AppRow(
                            app = app,
                            installedApp = installed[app.packageName],
                            progress = progress[app.packageName],
                            iconModel = iconRequest(context, settings, app),
                            onInstall = { installApp(app) },
                        )
                    }
                }
            }
        }
    }
}

private fun iconRequest(
    context: android.content.Context,
    settings: Settings,
    app: CatalogApp,
): ImageRequest? {
    val path = app.iconPath ?: return null
    val url = "${settings.baseUrl.trimEnd('/')}/${path.trimStart('/')}"
    val b = ImageRequest.Builder(context).data(url)
    if (settings.token.isNotEmpty()) b.addHeader("Authorization", "Bearer ${settings.token}")
    return b.build()
}

private data class InstalledApp(
    val versionCode: Long,
    val sha256: String,
)

private fun sha256File(path: String): String {
    val digest = MessageDigest.getInstance("SHA-256")
    FileInputStream(path).use { input ->
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        while (true) {
            val read = input.read(buffer)
            if (read <= 0) break
            digest.update(buffer, 0, read)
        }
    }
    return digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
}

@Composable
private fun AppRow(
    app: CatalogApp,
    installedApp: InstalledApp?,
    progress: Float?,
    iconModel: ImageRequest?,
    onInstall: () -> Unit,
) {
    val sameVersionDifferentApk = installedApp != null &&
        installedApp.versionCode == app.versionCode &&
        app.sha256.isNotBlank() &&
        !installedApp.sha256.equals(app.sha256, ignoreCase = true)
    val updateAvailable = installedApp != null &&
        (installedApp.versionCode < app.versionCode || sameVersionDifferentApk)
    val upToDate = installedApp != null &&
        installedApp.versionCode >= app.versionCode &&
        !sameVersionDifferentApk

    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        AsyncImage(
            model = iconModel,
            contentDescription = null,
            modifier = Modifier.size(48.dp).clip(RoundedCornerShape(10.dp)),
        )
        Spacer(Modifier.width(16.dp))
        Column(Modifier.weight(1f)) {
            Text(app.label, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                "v${app.versionName} · ${formatSize(app.sizeBytes)}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (progress != null) {
                Spacer(Modifier.size(6.dp))
                LinearProgressIndicator(progress = { progress }, modifier = Modifier.fillMaxWidth())
            }
        }
        Spacer(Modifier.width(12.dp))
        if (progress == null) {
            Button(onClick = onInstall, enabled = !upToDate) {
                Text(if (updateAvailable) "Update" else if (upToDate) "Installed" else "Install")
            }
        }
    }
}

private fun formatSize(bytes: Long): String {
    if (bytes <= 0) return "?"
    val mb = bytes / (1024.0 * 1024.0)
    return if (mb >= 1) "%.1f MB".format(mb) else "%.0f KB".format(bytes / 1024.0)
}
