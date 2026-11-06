cmake_minimum_required(VERSION 3.18.1)

# The libVLC calls libvlc-android does not expose in Java - see
# vlc_player_geometry.c, vlc_player_subtitles.c and vlc_player_fonts.c. Links
# nothing of libVLC's: the symbols are resolved at run time from the libvlc.so
# the AAR ships and has already loaded.
project(vlc_player_geometry C)

# Shared with the other platforms.
set(VLC_PLAYER_NATIVE ${CMAKE_CURRENT_SOURCE_DIR}/../../../../src/native)

add_library(vlc_player_geometry SHARED
    vlc_player_geometry.c
    vlc_player_subtitles.c
    vlc_player_fonts.c
    ${VLC_PLAYER_NATIVE}/vlc_subtitle_look.c)
target_include_directories(vlc_player_geometry PRIVATE ${VLC_PLAYER_NATIVE})
target_link_libraries(vlc_player_geometry dl)
