package com.viliana.weekglass.weekglass

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ApkSignerPolicyTest {
    private val legacy = BuildConfig.LEGACY_CERTIFICATE_SHA256
    private val production = BuildConfig.PRODUCTION_CERTIFICATE_SHA256
    private val rotated = listOf(legacy, production)
    private val firstRotationSdk = BuildConfig.SIGNER_ROTATION_MIN_SDK

    @Test fun sameCurrentSignersRemainValidForLegacyProductionAndLocalBuilds() {
        assertTrue(ApkSignerPolicy.accepts(24, setOf(legacy), setOf(legacy), emptyList()))
        assertTrue(ApkSignerPolicy.accepts(firstRotationSdk, setOf(production), setOf(production), rotated))
        val local = setOf("testSigner1", "testSigner2")
        assertTrue(ApkSignerPolicy.accepts(firstRotationSdk, local, local, emptyList()))
        assertFalse(ApkSignerPolicy.accepts(firstRotationSdk, emptySet(), emptySet(), emptyList()))
    }

    @Test fun onlyThePinnedForwardRotationIsAcceptedOnSupportedAndroid() {
        assertTrue(ApkSignerPolicy.accepts(firstRotationSdk, setOf(legacy), setOf(production), rotated))
        assertFalse(ApkSignerPolicy.accepts(firstRotationSdk - 1, setOf(legacy), setOf(production), rotated))
        assertFalse(ApkSignerPolicy.accepts(firstRotationSdk, setOf(production), setOf(legacy), rotated.reversed()))
        assertFalse(ApkSignerPolicy.accepts(firstRotationSdk, setOf(legacy), setOf(production), listOf(production)))
        assertFalse(ApkSignerPolicy.accepts(firstRotationSdk, setOf(legacy), setOf(production), rotated.reversed()))
    }

    @Test fun anotherDescendantOrDifferentSignerSetIsNotTrusted() {
        assertFalse(ApkSignerPolicy.accepts(firstRotationSdk, setOf(legacy), setOf("other"), listOf(legacy, "other")))
        assertFalse(ApkSignerPolicy.accepts(firstRotationSdk, setOf("other"), setOf(production), rotated))
        assertFalse(ApkSignerPolicy.accepts(firstRotationSdk, setOf(legacy), setOf(legacy, production), rotated))
    }
}
