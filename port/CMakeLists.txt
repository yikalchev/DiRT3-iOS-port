cmake_minimum_required(VERSION 3.24)
project(DIRT3Recomp
    VERSION 0.1.0
    LANGUAGES C CXX
    DESCRIPTION "DiRT 3 (BLES01548) -- native PS3 recompilation for iOS"
)

set(CMAKE_C_STANDARD 17)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------
# PS3RECOMP_DIR: the ps3recomp runtime checkout (vendor/ps3recomp).
# RECOMP_DIR:    DiRT 3's lifted PPU code (tools/analyze_dirt3.sh -> port/recompiled).
# SPU_DIR:       DiRT 3's lifted SPU images and registry (-> port/spu).
if(NOT DEFINED PS3RECOMP_DIR)
    get_filename_component(PS3RECOMP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../vendor/ps3recomp" ABSOLUTE)
endif()
get_filename_component(PS3RECOMP_DIR "${PS3RECOMP_DIR}" ABSOLUTE)
set(RECOMP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/recompiled" CACHE PATH "Lifted DiRT 3 PPU sources")
set(SPU_DIR "${CMAKE_CURRENT_SOURCE_DIR}/spu" CACHE PATH "Lifted DiRT 3 SPU images")
get_filename_component(RECOMP_DIR "${RECOMP_DIR}" ABSOLUTE)
get_filename_component(SPU_DIR "${SPU_DIR}" ABSOLUTE)

message(STATUS "ps3recomp SDK:   ${PS3RECOMP_DIR}")
message(STATUS "Lifted PPU:      ${RECOMP_DIR}")
message(STATUS "Lifted SPU:      ${SPU_DIR}")

if(NOT EXISTS "${RECOMP_DIR}/ppu_recomp.h")
    message(FATAL_ERROR "No ppu_recomp.h in ${RECOMP_DIR}. Run tools/analyze_dirt3.sh first.")
endif()
file(GLOB RECOMP_SOURCES CONFIGURE_DEPENDS "${RECOMP_DIR}/*.c" "${RECOMP_DIR}/*.cpp")
if(NOT RECOMP_SOURCES)
    message(FATAL_ERROR "${RECOMP_DIR} has no lifted sources. Run tools/analyze_dirt3.sh first.")
endif()
list(LENGTH RECOMP_SOURCES RECOMP_SOURCE_COUNT)
message(STATUS "PPU sources:     ${RECOMP_SOURCE_COUNT} file(s)")

# ---------------------------------------------------------------------------
# ps3recomp runtime library
# ---------------------------------------------------------------------------
add_subdirectory("${PS3RECOMP_DIR}" "${CMAKE_BINARY_DIR}/ps3recomp_sdk" EXCLUDE_FROM_ALL)

# Emit zero-initialized C globals as ordinary definitions: Darwin's linker
# over-aligns large common blocks and then warns when clamping them.
if(APPLE AND CMAKE_C_COMPILER_ID MATCHES "Clang")
    target_compile_options(ps3recomp_runtime PRIVATE "$<$<COMPILE_LANGUAGE:C>:-fno-common>")
endif()

# ---------------------------------------------------------------------------
# HLE NID table (firmware import -> runtime handler), generated for every module
# ---------------------------------------------------------------------------
find_package(Python3 COMPONENTS Interpreter REQUIRED)
set(HLE_NID_TABLE "${CMAKE_CURRENT_BINARY_DIR}/ppu_hle_nids.cpp")
file(GLOB_RECURSE HLE_NID_SOURCES CONFIGURE_DEPENDS "${PS3RECOMP_DIR}/libs/*.c")
set(HLE_NID_SOURCE_LIST "${CMAKE_CURRENT_BINARY_DIR}/hle_nid_sources.txt")
file(GENERATE OUTPUT "${HLE_NID_SOURCE_LIST}" CONTENT "${HLE_NID_SOURCES}\n")
add_custom_command(
    OUTPUT "${HLE_NID_TABLE}"
    COMMAND "${Python3_EXECUTABLE}" "${PS3RECOMP_DIR}/tools/gen_hle_nids.py"
            --out "${HLE_NID_TABLE}" --all
    DEPENDS "${PS3RECOMP_DIR}/tools/gen_hle_nids.py" "${PS3RECOMP_DIR}/tools/nid_database.py"
            ${HLE_NID_SOURCES} "${HLE_NID_SOURCE_LIST}"
    COMMENT "Generating the HLE NID -> handler table")

# The PPU boot scaffold #includes the per-game ppu_recomp.h, so it is built here.
set(PS3RECOMP_SCAFFOLD
    "${PS3RECOMP_DIR}/runtime/ppu/ppu_loader.cpp"
    "${PS3RECOMP_DIR}/runtime/ppu/ppu_hle.cpp"
    "${PS3RECOMP_DIR}/runtime/ppu/ppu_fs.cpp"
    "${PS3RECOMP_DIR}/runtime/ppu/ppu_sysprx.cpp"
)

# ---------------------------------------------------------------------------
# Lifted SPU images (FMOD, SPURS job modules, ...)
# ---------------------------------------------------------------------------
file(GLOB SPU_LIFTED CONFIGURE_DEPENDS "${SPU_DIR}/*/spu_recomp.c")
if(NOT SPU_LIFTED OR NOT EXISTS "${SPU_DIR}/spu_workloads.c")
    message(FATAL_ERROR "No lifted SPU images / spu_workloads.c in ${SPU_DIR}. Run tools/analyze_dirt3.sh first.")
endif()
list(LENGTH SPU_LIFTED SPU_IMAGE_COUNT)
message(STATUS "SPU images:      ${SPU_IMAGE_COUNT}")
# spu_dispatch_mt.c is the musttail indirect-branch path; it must be built here
# by clang with the lifted units.
set(SPU_SOURCES ${SPU_LIFTED} "${SPU_DIR}/spu_workloads.c"
    "${PS3RECOMP_DIR}/runtime/spu/spu_dispatch_mt.c")
# SPURS job binaries (tools/lift_dirt3_jobs.py) register from a constructor.
if(EXISTS "${SPU_DIR}/dirt3_jobs_register.c")
    list(APPEND SPU_SOURCES "${SPU_DIR}/dirt3_jobs_register.c")
else()
    message(WARNING "No ${SPU_DIR}/dirt3_jobs_register.c -- run tools/lift_dirt3_jobs.py")
endif()
set_source_files_properties(${SPU_SOURCES} PROPERTIES
    INCLUDE_DIRECTORIES "${PS3RECOMP_DIR}/runtime/spu"
    COMPILE_DEFINITIONS "SPU_USE_DISPATCH_MT;SPU_LS_DIAGNOSTICS=0"
    COMPILE_OPTIONS "-O2")

# ---------------------------------------------------------------------------
# Game library (linked into the iOS app by Xcode)
# ---------------------------------------------------------------------------
add_library(${PROJECT_NAME} STATIC
    main.cpp
    gpu_read_sync.cpp
    stubs.cpp
    ${PS3RECOMP_SCAFFOLD}
    ${HLE_NID_TABLE}
    ${RECOMP_SOURCES}
    ${SPU_SOURCES}
)

# Observer-only SPU local-store probes stay out of the runtime as well.
target_compile_definitions(ps3recomp_runtime PRIVATE SPU_LS_DIAGNOSTICS=0)

# Offline diagnostics recorder (session logs under Documents/logs/performance).
option(DIRT3_IOS_DIAGNOSTICS "Offline iOS session logs and FPS tracking" ON)
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    foreach(metric_target IN ITEMS ${PROJECT_NAME} ps3recomp_runtime)
        target_compile_definitions(${metric_target} PRIVATE
            PS3_PASSIVE_METRICS=$<BOOL:${DIRT3_IOS_DIAGNOSTICS}>)
    endforeach()
endif()

target_include_directories(${PROJECT_NAME} PRIVATE
    "${RECOMP_DIR}"
    "${PS3RECOMP_DIR}/include"
    "${PS3RECOMP_DIR}/runtime/ppu"
    "${PS3RECOMP_DIR}/runtime/spu"
    "${PS3RECOMP_DIR}/runtime/memory"
    "${PS3RECOMP_DIR}/runtime/syscalls"
    "${PS3RECOMP_DIR}/runtime/platform"
    "${PS3RECOMP_DIR}/libs/video"
    "${CMAKE_CURRENT_SOURCE_DIR}"
)
target_link_libraries(${PROJECT_NAME} PRIVATE ps3recomp_runtime)
set_target_properties(${PROJECT_NAME} PROPERTIES LINKER_LANGUAGE CXX)

target_compile_options(${PROJECT_NAME} PRIVATE
    -Wall -Wextra -Wno-unused-parameter
    -fno-strict-aliasing
    # Lifted PPC arithmetic is written as signed C arithmetic and must wrap.
    -fwrapv)

# Generated units: warnings off, and no FP contraction (a PPC fmadd is spelled
# as one where the lifter means one; arm64 would otherwise fuse others).
set_source_files_properties(${RECOMP_SOURCES} PROPERTIES COMPILE_OPTIONS "-w;-ffp-contract=off")

# ---------------------------------------------------------------------------
# Link description for Xcode
# ---------------------------------------------------------------------------
# Never built on iOS (UIKit owns main); tools/build_xcode_runtime.py reads its
# link line through the CMake File API. Whole-archive keeps the constructor-
# registered SPU tables.
add_executable(dirt3_runner cli_main.cpp)
target_link_libraries(dirt3_runner PRIVATE "$<LINK_LIBRARY:WHOLE_ARCHIVE,${PROJECT_NAME}>")
set_target_properties(dirt3_runner PROPERTIES EXCLUDE_FROM_ALL TRUE)
