package com.lagradost.cloudstream3

/**
 * Hook mà một provider có thể cài để nhận vị trí phát THẬT trong lúc người dùng xem
 * (vd. báo tiến trình/tích điểm lên backend của chính site).
 *
 * Đây là interface của bản CloudStream tuỳ biến (fork) mà một số plugin, trong đó có cs347
 * (`class Anime47Provider : MainAPI(), WatchProgressListener`), được biên dịch theo. Thư viện
 * CloudStream gốc mà engine nạp KHÔNG có interface này, nên thiếu nó thì plugin không nạp được
 * (NoClassDefFoundError). Khai báo ở đây, cùng package và chữ ký, để các plugin đó nạp và chạy được.
 */
interface WatchProgressListener {
    /**
     * @param data đúng chuỗi đã truyền cho `loadLinks(data, ...)` của tập đang phát.
     * @param positionMs vị trí phát hiện tại (ms).
     * @param durationMs tổng thời lượng (ms).
     */
    suspend fun onWatchProgress(data: String, positionMs: Long, durationMs: Long)
}
