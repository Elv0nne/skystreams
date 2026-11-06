package dev.akash.cs3engine.android.ui

import android.annotation.SuppressLint
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import dev.akash.cs3engine.ui.PageStandIn

/**
 * Where an extension's page (its WebView) sat in its window while the sheet shows it: [standIn] holds its place
 * (index and layout) and reads as the page in the window's tree, so the page node keeps its number (Task 2).
 */
internal class PageSlot private constructor(val page: WebView, val session: Int, val standIn: StandIn) {
    /** Holds the page's place, drawing nothing. */
    @SuppressLint("ViewConstructor")
    class StandIn(override val page: WebView) : View(page.context), PageStandIn

    /** Puts the page back where the stand-in is; false when the extension took the stand-in out meanwhile. */
    fun putBack(): Boolean {
        val parent = standIn.parent as? ViewGroup ?: return false
        val index = parent.indexOfChild(standIn)
        (page.parent as? ViewGroup)?.removeView(page)
        parent.removeViewAt(index)
        parent.addView(page, index, standIn.layoutParams)
        return true
    }

    companion object {
        /** Takes [page] out of its window, leaving a stand-in in its place; null when it has no parent. */
        fun takeOut(page: WebView, session: Int): PageSlot? {
            val parent = page.parent as? ViewGroup ?: return null
            val index = parent.indexOfChild(page)
            val params = page.layoutParams
            val standIn = StandIn(page)
            parent.removeViewAt(index)
            parent.addView(standIn, index, params)
            return PageSlot(page, session, standIn)
        }
    }
}
