package com.viliana.weekglass.weekglass

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ManagedUpdateCompletionTest {
    @Test
    fun pollingBeforeCompletionBroadcastStillLeavesACompletionSignal() {
        var systemRowExists = true
        val events = mutableListOf<String>()
        completeManagedUpdate(
            importVerified = { events.add("imported") },
            publishCompletion = {
                assertTrue(systemRowExists)
                events.add("notified")
            },
            releaseSystemDownload = {
                systemRowExists = false
                events.add("released")
            },
        )
        // The later receiver cannot find the consumed row. Polling has already
        // published the same notification before yielding to that receiver.
        assertFalse(systemRowExists)
        assertEquals(listOf("imported", "notified", "released"), events)
    }

    @Test
    fun aFailedImportDoesNotAnnounceSuccessOrReleaseTheRecoverableDownload() {
        val events = mutableListOf<String>()
        val failure = runCatching {
            completeManagedUpdate(
                importVerified = { throw ManagedDownloadFailure("storage") },
                publishCompletion = { events.add("notified") },
                releaseSystemDownload = { events.add("released") },
            )
        }.exceptionOrNull()
        assertEquals("storage", (failure as ManagedDownloadFailure).reason)
        assertTrue(events.isEmpty())
    }
}
