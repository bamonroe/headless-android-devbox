package com.bam.store.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * Talks to the static repository: fetches index.json and streams APK downloads.
 * All network paths are resolved relative to [Settings.baseUrl].
 */
class RepoClient(private val settings: Settings) {

    private val http = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .build()

    private fun url(repoRelative: String): String {
        val base = settings.baseUrl.trimEnd('/')
        return "$base/${repoRelative.trimStart('/')}"
    }

    private fun Request.Builder.auth(): Request.Builder {
        val t = settings.token
        if (t.isNotEmpty()) header("Authorization", "Bearer $t")
        return this
    }

    suspend fun fetchCatalog(): Catalog = withContext(Dispatchers.IO) {
        val req = Request.Builder().url(url("index.json")).auth().build()
        http.newCall(req).execute().use { resp ->
            if (!resp.isSuccessful) throw IOException("index.json → HTTP ${resp.code}")
            val body = resp.body?.string() ?: throw IOException("empty index.json")
            Catalog.parse(body)
        }
    }

    /**
     * Downloads [app]'s APK into the app cache and returns the file. [onProgress]
     * receives a 0f..1f fraction (or -1f when total size is unknown).
     */
    suspend fun downloadApk(
        app: CatalogApp,
        cacheDir: File,
        onProgress: (Float) -> Unit,
    ): File = withContext(Dispatchers.IO) {
        val req = Request.Builder().url(url(app.apkPath)).auth().build()
        http.newCall(req).execute().use { resp ->
            if (!resp.isSuccessful) throw IOException("${app.apkPath} → HTTP ${resp.code}")
            val body = resp.body ?: throw IOException("empty APK body")
            val total = if (app.sizeBytes > 0) app.sizeBytes else body.contentLength()
            val out = File(cacheDir, "${app.packageName}-${app.versionCode}.apk")
            body.byteStream().use { input ->
                out.outputStream().use { sink ->
                    val buf = ByteArray(64 * 1024)
                    var read: Int
                    var written = 0L
                    while (input.read(buf).also { read = it } >= 0) {
                        sink.write(buf, 0, read)
                        written += read
                        onProgress(if (total > 0) written.toFloat() / total else -1f)
                    }
                }
            }
            out
        }
    }
}
