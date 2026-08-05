package com.bam.store

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.bam.store.data.Settings
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

/**
 * A small instrumented suite that needs a real [android.content.Context], so it can only
 * run on a device/emulator. It doubles as the smoke test for the toolchain's
 * `connected-test.sh`, which builds here and instruments over the emulator's own adb.
 */
@RunWith(AndroidJUnit4::class)
class SettingsInstrumentedTest {

    private val settings: Settings
        get() = Settings(InstrumentationRegistry.getInstrumentation().targetContext)

    @Test
    fun packageUnderTestIsTheStore() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        assertEquals("com.bam.store", context.packageName)
    }

    @Test
    fun baseUrlRoundTripsAndTrims() {
        settings.baseUrl = "  http://example.invalid/repo/  "
        assertEquals("http://example.invalid/repo/", settings.baseUrl)

        settings.baseUrl = Settings.DEFAULT_URL
        assertEquals(Settings.DEFAULT_URL, settings.baseUrl)
    }

    @Test
    fun tokenRoundTripsAndTrims() {
        settings.token = "  s3cret  "
        assertEquals("s3cret", settings.token)

        settings.token = ""
        assertEquals("", settings.token)
    }
}
