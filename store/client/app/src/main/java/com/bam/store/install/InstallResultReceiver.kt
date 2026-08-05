package com.bam.store.install

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow

/** Outcome of an install session, surfaced to the UI. */
sealed interface InstallEvent {
    val packageName: String
    data class Success(override val packageName: String) : InstallEvent
    data class Failure(override val packageName: String, val message: String) : InstallEvent
}

/**
 * App-wide bus for install results. The receiver is instantiated by the system,
 * so it publishes onto this process-static flow that the UI collects.
 */
object InstallEvents {
    private val _events = MutableSharedFlow<InstallEvent>(extraBufferCapacity = 8)
    val events: SharedFlow<InstallEvent> = _events
    fun emit(event: InstallEvent) { _events.tryEmit(event) }
}

/**
 * Handles [PackageInstaller] status callbacks. The common case is
 * STATUS_PENDING_USER_ACTION — the OS wants the user to confirm the install, so
 * we launch the confirmation dialog it hands us. Terminal statuses are forwarded
 * to [InstallEvents] for the catalog to react to.
 */
class InstallResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pkg = intent.getStringExtra(ApkInstaller.EXTRA_PACKAGE) ?: "?"
        val status = intent.getIntExtra(
            PackageInstaller.EXTRA_STATUS,
            PackageInstaller.STATUS_FAILURE,
        )
        when (status) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                @Suppress("DEPRECATION")
                val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                confirm?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                if (confirm != null) context.startActivity(confirm)
            }
            PackageInstaller.STATUS_SUCCESS -> {
                InstallEvents.emit(InstallEvent.Success(pkg))
            }
            else -> {
                val msg = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
                    ?: "install failed (status $status)"
                InstallEvents.emit(InstallEvent.Failure(pkg, msg))
            }
        }
    }
}
