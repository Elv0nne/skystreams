// Adapted from CloudStream (https://github.com/recloudstream/cloudstream), GPL-3.0.
package com.lagradost.cloudstream3

import android.content.Intent
import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.LayoutInflaterCompat
import dev.akash.cs3engine.android.RestartGuard
import dev.akash.cs3engine.android.ui.ExtensionLayoutIds
import dev.akash.cs3engine.android.ui.RestoredFragments

/**
 * The host app's activity must extend this: plugins cast their Context to CloudStream's
 * MainActivity or to AppCompatActivity when they open dialogs, and subscribe to its events.
 * Extensions can't restart the app through it (see RestartGuard; the application context is the
 * app's ExtensionHostApplication). Android restoring it leaves their fragments out (see RestoredFragments).
 */
open class MainActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // Before super, which would install AppCompat's own: views are made through AppCompat's delegate, and an
        // extension's layout keeps its ids (see ExtensionLayoutIds).
        LayoutInflaterCompat.setFactory2(layoutInflater, ExtensionLayoutIds(delegate::createView))
        // Before super, which restores the fragments: an extension's can't come back.
        supportFragmentManager.fragmentFactory = RestoredFragments(supportFragmentManager.fragmentFactory)
        super.onCreate(savedInstanceState)
    }

    override fun startActivity(intent: Intent?) {
        RestartGuard.check(this, intent)
        super.startActivity(intent)
    }

    override fun startActivity(intent: Intent?, options: Bundle?) {
        RestartGuard.check(this, intent)
        super.startActivity(intent, options)
    }

    companion object {
        val afterPluginsLoadedEvent get() = MainActivityEvents.afterPluginsLoadedEvent
        val mainPluginsLoadedEvent get() = MainActivityEvents.mainPluginsLoadedEvent
        val afterRepositoryLoadedEvent get() = MainActivityEvents.afterRepositoryLoadedEvent
        val bookmarksUpdatedEvent get() = MainActivityEvents.bookmarksUpdatedEvent
        val reloadHomeEvent get() = MainActivityEvents.reloadHomeEvent
        val reloadLibraryEvent get() = MainActivityEvents.reloadLibraryEvent
        val reloadAccountEvent get() = MainActivityEvents.reloadAccountEvent
    }
}
