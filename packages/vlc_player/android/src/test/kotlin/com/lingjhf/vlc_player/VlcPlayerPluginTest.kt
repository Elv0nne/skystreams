package com.lingjhf.vlc_player

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.mockito.Mockito
import kotlin.test.Test

/*
 * This demonstrates a simple unit test of the Kotlin portion of this plugin's
 * implementation.
 *
 * Once you have built the plugin's example app, you can run these tests from
 * the command line by running `./gradlew testDebugUnitTest` in the
 * `example/android/` directory, or you can run them directly from IDEs that
 * support JUnit such as Android Studio.
 */

internal class VlcPlayerPluginTest {
    @Test
    fun onMethodCall_withoutViewId_returnsInvalidArgs() {
        val plugin = VlcPlayerPlugin()

        val call = MethodCall("play", null)
        val mockResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(call, mockResult)

        Mockito.verify(mockResult).error(
            "invalid_args",
            "A valid viewId is required.",
            null,
        )
    }

    @Test
    fun onMethodCall_deviceCalls_answerWithoutAPlayer() {
        // The device's volume and brightness name no player: answered ahead of the viewId guard, here with no engine
        // or activity attached at all.
        val plugin = VlcPlayerPlugin()

        val brightness: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(MethodCall("getScreenBrightness", null), brightness)
        Mockito.verify(brightness).success(null)

        val fixed: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(MethodCall("isSystemVolumeFixed", null), fixed)
        Mockito.verify(fixed).success(false)

        val shown: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(MethodCall("setPlayerShown", mapOf("shown" to true)), shown)
        Mockito.verify(shown).success(null)
    }

    @Test
    fun onMethodCall_setSystemVolume_withoutALevel_returnsInvalidArgs() {
        val plugin = VlcPlayerPlugin()

        val result: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(MethodCall("setSystemVolume", emptyMap<String, Any>()), result)

        Mockito.verify(result).error("invalid_args", "A level is required.", null)
    }
}
