# LuaJIT and sol2 (header-only). TACTICS_DEPS_DIR holds luajit/{include,lib,bin} and sol2/include, for example
# copied from vcpkg (luajit:x64-windows, sol2). Only these folders go on the include path: a vcpkg include root
# also holds Boost/zlib headers that would shadow the core's.
set(TACTICS_DEPS_DIR "${CMAKE_SOURCE_DIR}/../deps" CACHE PATH "Folder with luajit/ and sol2/")
find_path(TACTICS_LUAJIT_INCLUDE_DIR luajit.h PATHS "${TACTICS_DEPS_DIR}/luajit/include" PATH_SUFFIXES luajit NO_DEFAULT_PATH REQUIRED)
find_library(TACTICS_LUAJIT_LIBRARY NAMES lua51 luajit-5.1 PATHS "${TACTICS_DEPS_DIR}/luajit/lib" NO_DEFAULT_PATH REQUIRED)
find_file(TACTICS_LUAJIT_RUNTIME NAMES lua51.dll PATHS "${TACTICS_DEPS_DIR}/luajit/bin" NO_DEFAULT_PATH)
find_path(TACTICS_SOL2_INCLUDE_DIR sol/sol.hpp PATHS "${TACTICS_DEPS_DIR}/sol2/include" NO_DEFAULT_PATH REQUIRED)
set(TACTICS_DEFINITIONS SOL_LUAJIT=1 SOL_ALL_SAFETIES_ON=1 SOL_PRINT_ERRORS=0)
