package android.app;

/** Reports the JVM heap as the device's memory; plugins use it to size caches and parallelism. */
public class ActivityManager {
    public static class MemoryInfo {
        public long availMem;
        public long totalMem;
        public long threshold;
        public boolean lowMemory;
    }

    public void getMemoryInfo(MemoryInfo outInfo) {
        Runtime runtime = Runtime.getRuntime();
        outInfo.totalMem = runtime.maxMemory();
        outInfo.availMem = runtime.maxMemory() - (runtime.totalMemory() - runtime.freeMemory());
        outInfo.threshold = outInfo.totalMem / 10;
        outInfo.lowMemory = outInfo.availMem < outInfo.threshold;
    }

    public boolean isLowRamDevice() { return false; }
    public int getMemoryClass() { return (int) (Runtime.getRuntime().maxMemory() / (1024 * 1024)); }
}
