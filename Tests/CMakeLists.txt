cmake_minimum_required(VERSION 3.16)
project(aerial_lock_tests LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(AERIAL_LOCK_SOURCE "${CMAKE_CURRENT_SOURCE_DIR}/.." CACHE PATH
    "aerial-lock source tree used by the test fixtures")
find_package(Qt6 REQUIRED COMPONENTS Core Gui Qml Quick Test)

add_executable(native-input-probe native-input-probe.cpp)
target_link_libraries(native-input-probe PRIVATE
    Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick Qt6::Test)

enable_testing()
add_test(NAME native-input-probe
    COMMAND native-input-probe "${AERIAL_LOCK_SOURCE}/Tests/auth-input-fixture.qml")
add_test(NAME native-input-migration
    COMMAND native-input-probe --migration "${AERIAL_LOCK_SOURCE}/Tests/auth-input-fixture.qml")

add_executable(connection-loss-probe connection-loss-probe.cpp)
target_link_libraries(connection-loss-probe PRIVATE Qt6::Core pthread)
find_package(Python3 REQUIRED COMPONENTS Interpreter)
# VM integration drivers validate an operator-supplied owned-instance manifest
# (Tests/README.md "Owned manifest"); its regression runs only when one is given.
set(AERIAL_LOCK_VM_RECORD "" CACHE FILEPATH "Operator-supplied owned VM/session manifest")
if(AERIAL_LOCK_VM_RECORD)
    add_test(NAME owned-instance
        COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/test-owned-instance.py"
                --vm-record "${AERIAL_LOCK_VM_RECORD}")
endif()
add_test(NAME panel-output-paths
    COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/test-panel-output-paths.py")
add_test(NAME driver-wait-order
    COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/test-driver-wait-order.py")
add_test(NAME blocked-latch
    COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/test-blocked-latch.py"
            "$<TARGET_FILE:connection-loss-probe>")
find_package(PkgConfig REQUIRED)
pkg_check_modules(WAYLAND REQUIRED IMPORTED_TARGET wayland-client)
target_link_libraries(connection-loss-probe PRIVATE Qt6::Gui PkgConfig::WAYLAND)
add_library(guard-logger-trap SHARED guard-logger-trap.cpp)
target_link_libraries(guard-logger-trap PRIVATE Qt6::Core ${CMAKE_DL_LIBS})
add_test(NAME supervisor-session
    COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/test-supervisor-session.py"
            "${AERIAL_LOCK_SOURCE}/supervisor/aerial-lock-supervisor")
add_test(NAME build-config
    COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/test-build-config.py"
            "${AERIAL_LOCK_SOURCE}")
pkg_check_modules(MPV REQUIRED IMPORTED_TARGET mpv)
add_library(full-caller-faults SHARED full-caller-faults.c)
target_link_libraries(full-caller-faults PRIVATE PkgConfig::MPV pthread ${CMAKE_DL_LIBS})
find_program(QMLTESTRUNNER qmltestrunner PATHS /usr/lib/qt6/bin /usr/lib64/qt6/bin REQUIRED)
add_test(NAME media-fallback
    COMMAND "${QMLTESTRUNNER}" -input "${AERIAL_LOCK_SOURCE}/Tests/media-fallback-fault.qml"
            MediaFallbackFault::test_core_failure_keeps_solid_scenery_and_reports_once)
set_tests_properties(media-fallback PROPERTIES ENVIRONMENT
    "LD_PRELOAD=$<TARGET_FILE:full-caller-faults>;AERIAL_TEST_FULL_CALLER_FAULT=core-create;QT_QPA_PLATFORM=offscreen")
# Needs a rendering Qt platform (e.g. inside a Wayland session); skips on offscreen.
add_test(NAME media-fallback-render
    COMMAND "${QMLTESTRUNNER}" -input "${AERIAL_LOCK_SOURCE}/Tests/media-fallback-fault.qml"
            MediaFallbackFault::test_render_failure_stops_hidden_playback)
# Native desktop input and pointer probes used by the VM output-failover drivers.
add_executable(desktop-input-probe desktop-input-probe.cpp)
target_link_libraries(desktop-input-probe PRIVATE Qt6::Gui Qt6::Quick)
find_program(WAYLAND_SCANNER wayland-scanner REQUIRED)
add_custom_command(OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/virtual-pointer-client.h"
    COMMAND "${WAYLAND_SCANNER}" client-header "${CMAKE_CURRENT_SOURCE_DIR}/virtual-pointer.xml"
            "${CMAKE_CURRENT_BINARY_DIR}/virtual-pointer-client.h"
    DEPENDS virtual-pointer.xml)
add_custom_command(OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/virtual-pointer-protocol.c"
    COMMAND "${WAYLAND_SCANNER}" private-code "${CMAKE_CURRENT_SOURCE_DIR}/virtual-pointer.xml"
            "${CMAKE_CURRENT_BINARY_DIR}/virtual-pointer-protocol.c"
    DEPENDS virtual-pointer.xml)
add_executable(virtual-pointer-probe virtual-pointer-probe.c
    "${CMAKE_CURRENT_BINARY_DIR}/virtual-pointer-client.h"
    "${CMAKE_CURRENT_BINARY_DIR}/virtual-pointer-protocol.c")
target_include_directories(virtual-pointer-probe PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
target_link_libraries(virtual-pointer-probe PRIVATE PkgConfig::WAYLAND)
