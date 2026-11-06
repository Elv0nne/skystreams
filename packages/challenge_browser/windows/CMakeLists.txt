# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later. You should not increase this
# version, as doing so will cause the plugin to fail to compile for some
# customers of the plugin.
cmake_minimum_required(VERSION 3.14)

# Project-level configuration.
set(PROJECT_NAME "challenge_browser")
project(${PROJECT_NAME} LANGUAGES CXX)

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "challenge_browser_plugin")

# The WebView2 SDK from NuGet, pinned and checked: its headers and static loader, so no
# WebView2Loader.dll ships. No NuGet tool is needed.
set(WEBVIEW2_VERSION "1.0.4258.31")
set(WEBVIEW2_SHA256 "56f7f4b8bf9aee4b8efefbbdd4f67d5f74ebd1b100ed0806da71bf76af481aa9")
set(WEBVIEW2_DIR "${CMAKE_BINARY_DIR}/webview2-${WEBVIEW2_VERSION}")
if(NOT EXISTS "${WEBVIEW2_DIR}/build/native/include/WebView2.h")
  file(DOWNLOAD
    "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/${WEBVIEW2_VERSION}/microsoft.web.webview2.${WEBVIEW2_VERSION}.nupkg"
    "${WEBVIEW2_DIR}.zip"
    EXPECTED_HASH SHA256=${WEBVIEW2_SHA256})
  file(MAKE_DIRECTORY "${WEBVIEW2_DIR}")
  execute_process(COMMAND ${CMAKE_COMMAND} -E tar xf "${WEBVIEW2_DIR}.zip"
    WORKING_DIRECTORY "${WEBVIEW2_DIR}")
endif()
if(CMAKE_CXX_COMPILER_ARCHITECTURE_ID STREQUAL "ARM64")
  set(WEBVIEW2_ARCH "arm64")
else()
  set(WEBVIEW2_ARCH "x64")
endif()

list(APPEND PLUGIN_SOURCES
  "challenge_browser_plugin.cpp"
  "challenge_browser_plugin.h"
  "messages.g.cpp"
  "messages.g.h"
  "page.cpp"
  "page.h"
)

# Define the plugin library target. Its name must not be changed (see comment
# on PLUGIN_NAME above).
add_library(${PLUGIN_NAME} SHARED
  "include/challenge_browser/challenge_browser_plugin_c_api.h"
  "challenge_browser_plugin_c_api.cpp"
  ${PLUGIN_SOURCES}
)

# Apply a standard set of build settings that are configured in the
# application-level CMakeLists.txt. This can be removed for plugins that want
# full control over build settings.
apply_standard_settings(${PLUGIN_NAME})

# Symbols are hidden by default to reduce the chance of accidental conflicts
# between plugins. This should not be removed; any symbols that should be
# exported should be explicitly exported with the FLUTTER_PLUGIN_EXPORT macro.
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_include_directories(${PLUGIN_NAME} PRIVATE "${WEBVIEW2_DIR}/build/native/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter
  flutter_wrapper_plugin
  comctl32
  "${WEBVIEW2_DIR}/build/native/${WEBVIEW2_ARCH}/WebView2LoaderStatic.lib"
)

# List of absolute paths to libraries that should be bundled with the plugin.
# This list could contain prebuilt libraries, or libraries created by an
# external build triggered from this build file.
set(challenge_browser_bundled_libraries
  ""
  PARENT_SCOPE
)
