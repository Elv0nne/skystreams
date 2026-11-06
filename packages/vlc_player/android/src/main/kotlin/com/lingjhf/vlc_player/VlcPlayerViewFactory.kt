package com.lingjhf.vlc_player

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

internal class VlcPlayerViewFactory(
    private val messenger: BinaryMessenger,
    private val onCreate: (Long, VlcPlayerPlatformView) -> Unit,
    private val onDispose: (Long, VlcPlayerPlatformView) -> Unit,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(viewContext: Context, viewId: Int, args: Any?): PlatformView {
        val view = VlcPlayerPlatformView(
            viewContext,
            messenger,
            viewId.toLong(),
            readVlcOptions((args as? Map<*, *>)?.get("options")),
            readFit(args),
            VlcRenderTarget.VideoLayout(viewContext),
            onDispose,
        )
        onCreate(viewId.toLong(), view)
        return view
    }

    private fun readFit(args: Any?): String {
        return ((args as? Map<*, *>)?.get("fit") as? String) ?: "contain"
    }
}

/// The libVLC option list as Dart sent it, whichever channel it came down.
internal fun readVlcOptions(raw: Any?): ArrayList<String> {
    val options = ArrayList<String>()
    val rawOptions = raw as? List<*> ?: return options

    rawOptions.forEach { option ->
        if (option != null) {
            options.add(option.toString())
        }
    }
    return options
}
