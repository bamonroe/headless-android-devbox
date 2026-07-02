package com.bam.store.data

import android.content.Context

/**
 * Persists the connection settings for the repository: its base URL and an
 * optional bearer token (used only when the repo is served behind token auth).
 */
class Settings(context: Context) {
    private val prefs = context.getSharedPreferences("bam_store", Context.MODE_PRIVATE)

    var baseUrl: String
        get() = prefs.getString(KEY_URL, DEFAULT_URL) ?: DEFAULT_URL
        set(value) = prefs.edit().putString(KEY_URL, value.trim()).apply()

    var token: String
        get() = prefs.getString(KEY_TOKEN, "") ?: ""
        set(value) = prefs.edit().putString(KEY_TOKEN, value.trim()).apply()

    companion object {
        // Served as static files by Caddy over the tailnet (MagicDNS). Plain HTTP
        // is fine: Tailscale already encrypts + authenticates the connection.
        const val DEFAULT_URL = "http://apps.bam/"
        private const val KEY_URL = "base_url"
        private const val KEY_TOKEN = "token"
    }
}
