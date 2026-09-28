# Plugin build (the core's AC_PLUGIN_SOURCE_DIRS). A static module build (modules/mod-lonelyice-tactics) uses
# mod-lonelyice-tactics.cmake instead.
include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/TacticsDeps.cmake")

file(GLOB_RECURSE TACTICS_SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/src/*.cpp" "${CMAKE_CURRENT_SOURCE_DIR}/src/*.h")
AddPlugin(mod-lonelyice-tactics SOURCES ${TACTICS_SOURCES} plugin/plugin.cpp LINK mod-playerbots "${TACTICS_LUAJIT_LIBRARY}")
target_include_directories(mod-lonelyice-tactics PRIVATE "${TACTICS_LUAJIT_INCLUDE_DIR}" "${TACTICS_SOL2_INCLUDE_DIR}")
target_compile_definitions(mod-lonelyice-tactics PRIVATE ${TACTICS_DEFINITIONS})

# The loader searches the plugin library's folder for the DLLs it needs.
if (TACTICS_LUAJIT_RUNTIME)
  add_custom_command(TARGET mod-lonelyice-tactics POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${TACTICS_LUAJIT_RUNTIME}" "$<TARGET_FILE_DIR:mod-lonelyice-tactics>")
endif()
