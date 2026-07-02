package com.bam.store.install

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Installs a downloaded APK using the platform [PackageInstaller]. Because this
 * app is an ordinary (non-privileged) installer, every install triggers a system
 * confirmation dialog — that flow is handled in [InstallResultReceiver], which
 * this class registers as the session's status callback.
 */
object ApkInstaller {

    const val ACTION_INSTALL_STATUS = "com.bam.store.INSTALL_STATUS"

    /**
     * Writes [apk] into a new install session and commits it. Returns the session
     * id; the actual success/failure arrives asynchronously via a broadcast with
     * action [ACTION_INSTALL_STATUS] (see [InstallResultReceiver] / [InstallEvents]).
     */
    suspend fun install(context: Context, apk: File, packageName: String): Int =
        withContext(Dispatchers.IO) {
            val installer = context.packageManager.packageInstaller
            val params = PackageInstaller.SessionParams(
                PackageInstaller.SessionParams.MODE_FULL_INSTALL
            ).apply {
                setAppPackageName(packageName)
            }

            val sessionId = installer.createSession(params)
            installer.openSession(sessionId).use { session ->
                apk.inputStream().use { input ->
                    session.openWrite("base.apk", 0, apk.length()).use { out ->
                        input.copyTo(out)
                        session.fsync(out)
                    }
                }

                val statusIntent = Intent(ACTION_INSTALL_STATUS)
                    .setPackage(context.packageName)
                    .putExtra(EXTRA_PACKAGE, packageName)
                val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
                    PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                else
                    PendingIntent.FLAG_UPDATE_CURRENT
                val pending = PendingIntent.getBroadcast(context, sessionId, statusIntent, flags)
                session.commit(pending.intentSender)
            }
            sessionId
        }

    const val EXTRA_PACKAGE = "com.bam.store.extra.PACKAGE"
}
