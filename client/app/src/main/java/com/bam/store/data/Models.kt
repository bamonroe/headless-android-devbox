package com.bam.store.data

import org.json.JSONObject

/** A single publishable app, as described by one entry in the repo's index.json. */
data class CatalogApp(
    val packageName: String,
    val label: String,
    val versionName: String,
    val versionCode: Long,
    val minSdk: Int,
    val sizeBytes: Long,
    val sha256: String,
    /** Repo-relative path to the APK, e.g. "apks/com.bam.foo-12.apk". */
    val apkPath: String,
    /** Repo-relative path to the extracted icon, or null if none. */
    val iconPath: String?,
    val changelog: String?,
) {
    companion object {
        fun fromJson(o: JSONObject): CatalogApp = CatalogApp(
            packageName = o.getString("packageName"),
            label = o.optString("label", o.getString("packageName")),
            versionName = o.optString("versionName", "?"),
            versionCode = o.optLong("versionCode", 0),
            minSdk = o.optInt("minSdk", 0),
            sizeBytes = o.optLong("size", 0),
            sha256 = o.optString("sha256", ""),
            apkPath = o.getString("apk"),
            iconPath = o.optString("icon").ifBlank { null },
            changelog = o.optString("changelog").ifBlank { null },
        )
    }
}

/** Parsed contents of index.json. */
data class Catalog(
    val name: String,
    val apps: List<CatalogApp>,
) {
    companion object {
        fun parse(json: String): Catalog {
            val root = JSONObject(json)
            val repo = root.optJSONObject("repo")
            val arr = root.getJSONArray("apps")
            val apps = ArrayList<CatalogApp>(arr.length())
            for (i in 0 until arr.length()) {
                apps.add(CatalogApp.fromJson(arr.getJSONObject(i)))
            }
            return Catalog(
                name = repo?.optString("name", "BAM Store") ?: "BAM Store",
                apps = apps.sortedBy { it.label.lowercase() },
            )
        }
    }
}
