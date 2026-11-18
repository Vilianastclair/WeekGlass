# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(weekglass LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "weekglass")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

# The offline parser runs in a private stripped JRE; no Java on the user's PATH.
find_package(Python3 3.9 REQUIRED COMPONENTS Interpreter)
get_filename_component(WG_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../.." ABSOLUTE)
set(ENGINE "${WG_ROOT}/tooling/course_adapter_engine")
set(ENGINE_DIST "${CMAKE_CURRENT_BINARY_DIR}/course_parser")
file(GLOB ENGINE_INPUTS LIST_DIRECTORIES false CONFIGURE_DEPENDS "${ENGINE}/*.py" "${ENGINE}/*.zip"
     "${ENGINE}/src/*.kt" "${ENGINE}/licenses/*" "${ENGINE}/LICENSE*")
add_custom_command(OUTPUT "${ENGINE_DIST}/engine.jar"
  COMMAND "${Python3_EXECUTABLE}" "${ENGINE}/build.py" --dist "${ENGINE_DIST}"
  DEPENDS ${ENGINE_INPUTS} VERBATIM)
file(READ "${WG_ROOT}/tooling/versions.json" WG_VERSIONS)
string(REGEX MATCH "\"java\"[ \t\r\n]*:[ \t\r\n]*\\{[^}]*\"version\"[ \t\r\n]*:[ \t\r\n]*\"([^\"]+)\"" _ "${WG_VERSIONS}")
set(WG_JRE "${CMAKE_CURRENT_BINARY_DIR}/course_jre_${CMAKE_MATCH_1}")
add_custom_command(OUTPUT "${WG_JRE}/release"
  COMMAND "${Python3_EXECUTABLE}" "${WG_ROOT}/tooling/scripts/link_course_runtime.py" "${WG_JRE}"
  DEPENDS "${WG_ROOT}/tooling/scripts/link_course_runtime.py" VERBATIM)
add_custom_target(weekglass_course_adapter DEPENDS "${ENGINE_DIST}/engine.jar" "${WG_JRE}/release")
add_dependencies(${BINARY_NAME} weekglass_course_adapter)
set(ENGINE_DEST "${INSTALL_BUNDLE_DATA_DIR}/course_adapter")
install(FILES "${ENGINE_DIST}/engine.jar"
   "${CMAKE_CURRENT_SOURCE_DIR}/course_adapter/OpenJDK.txt"
   "${CMAKE_CURRENT_SOURCE_DIR}/course_adapter/parser.policy"
   DESTINATION "${ENGINE_DEST}" COMPONENT CourseAdapter)
install(DIRECTORY "${ENGINE_DIST}/lib" "${ENGINE_DIST}/licenses"
   DESTINATION "${ENGINE_DEST}" COMPONENT CourseAdapter)
install(DIRECTORY "${WG_JRE}/" DESTINATION "${ENGINE_DEST}/runtime" COMPONENT CourseAdapter)

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
