package com.lagradost.cloudstream3.ui.home

import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals

class HomeViewModelTest {
    @Test
    fun `a sync plugin reads an empty resume list`() = runBlocking {
        assertEquals(emptyList(), HomeViewModel.getResumeWatching())
    }
}
