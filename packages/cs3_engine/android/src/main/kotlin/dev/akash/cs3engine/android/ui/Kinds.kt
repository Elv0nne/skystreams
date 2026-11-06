package dev.akash.cs3engine.android.ui

import android.view.View
import android.view.WindowManager

/** A captured window's kind, for the sheet: a dropdown or menu (popup), a bottom sheet, an alert, or another dialog. */
internal object Kinds {
    fun of(root: View, params: WindowManager.LayoutParams): String = when {
        params.type in WindowManager.LayoutParams.FIRST_SUB_WINDOW..WindowManager.LayoutParams.LAST_SUB_WINDOW -> "popup"
        root.findViewById<View>(com.google.android.material.R.id.design_bottom_sheet) != null -> "sheet"
        root.findViewById<View>(android.R.id.button1) != null ||
            root.findViewById<View>(androidx.appcompat.R.id.buttonPanel) != null -> "alert"
        else -> "dialog"
    }
}
