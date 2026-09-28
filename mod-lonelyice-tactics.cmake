# Static module build (modules/mod-lonelyice-tactics): included by the core's modules/CMakeLists.txt after the
# `modules` target exists.
include("${CMAKE_CURRENT_LIST_DIR}/cmake/TacticsDeps.cmake")
target_include_directories(modules PRIVATE "${TACTICS_LUAJIT_INCLUDE_DIR}" "${TACTICS_SOL2_INCLUDE_DIR}")
target_link_libraries(modules PUBLIC "${TACTICS_LUAJIT_LIBRARY}")
target_compile_definitions(modules PRIVATE ${TACTICS_DEFINITIONS})
if (MSVC)
  target_compile_options(modules PRIVATE /bigobj)
endif()
if (TACTICS_LUAJIT_RUNTIME)
  install(FILES "${TACTICS_LUAJIT_RUNTIME}" DESTINATION "${CMAKE_INSTALL_PREFIX}")
endif()
install(DIRECTORY "${CMAKE_CURRENT_LIST_DIR}/lua/tactics/" DESTINATION "${CMAKE_INSTALL_PREFIX}/lua_scripts/tactics" OPTIONAL)
