package com.viliana.weekglass.weekglass

internal object ApkSignerPolicy {
    fun accepts(
        sdk: Int,
        installed: Set<String>,
        incoming: Set<String>,
        incomingHistory: List<String>,
    ): Boolean {
        if (installed.isEmpty() || incoming.isEmpty()) return false
        if (installed == incoming) return true

        val legacy = BuildConfig.LEGACY_CERTIFICATE_SHA256
        val production = BuildConfig.PRODUCTION_CERTIFICATE_SHA256
        // The verified lineage is directional. Neither a shared ancestor nor an arbitrary
        // certificate issued by the old key is enough to accept an update.
        return sdk >= BuildConfig.SIGNER_ROTATION_MIN_SDK &&
            installed == setOf(legacy) && incoming == setOf(production) &&
            incomingHistory == listOf(legacy, production)
    }
}
