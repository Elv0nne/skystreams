package dev.akash.cs3engine.android.ui

import android.content.Context
import android.view.View
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/** The sheet's view of an extension's page (`ExtensionPageView` on the Dart side): its own WebView, lent while it shows. */
internal class ExtensionPageFactory(private val ui: () -> AndroidUiHost?) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val params = args as Map<*, *>
        val session = (params["session"] as Number).toInt()
        val node = (params["node"] as Number).toInt()
        // The full-screen view's page keeps the D-pad and the keyboard (Phase 7c): a game gets every arrow.
        val keepFocus = params["keepFocus"] == true
        lateinit var container: ExtensionPageContainer
        container = ExtensionPageContainer(context, keepFocus) { direction -> ui()?.pageFocusLeft(container, direction) }
        ui()?.lendPage(session, node, container)
        return object : PlatformView {
            override fun getView(): View = container

            override fun dispose() {
                ui()?.returnPage(container)
            }
        }
    }

    companion object {
        const val VIEW_TYPE = "cs3_engine/page"
    }
}
