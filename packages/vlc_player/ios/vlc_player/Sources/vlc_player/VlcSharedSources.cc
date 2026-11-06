// The shared libVLC plumbing, compiled into both Darwin plugins.
//
// CocoaPods only globs source files inside the pod root, and the pod roots are
// ios/ and macos/, so `../src/native/*.cc` in a podspec is silently dropped.
// Pulling the translation unit in through the header search path keeps one
// copy of the code without teaching either podspec to reach outside itself.
#include "vlc_video_output.cc"
#include "vlc_subtitle_look.c"
