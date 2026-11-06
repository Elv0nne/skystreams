package dev.akash.cs3engine.ui

import android.view.View

/**
 * A view standing where an extension's page (its WebView) sat in its window while SkyStream's sheet shows the page
 * itself (Android): read as that page, with the page's number, so the sheet keeps the page it shows.
 */
interface PageStandIn {
    val page: View
}
