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

add_executable(connection-loss-probe connection-loss-probe.cpp)
target_link_libraries(connection-loss-probe PRIVATE Qt6::Core pthread)
find_package(Python3 REQUIRED COMPONENTS Interpreter)
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
pkg_check_modules(MPV REQUIRED IMPORTED_TARGET mpv)
add_library(full-caller-faults SHARED full-caller-faults.c)
target_link_libraries(full-caller-faults PRIVATE PkgConfig::MPV pthread ${CMAKE_DL_LIBS})
find_program(QMLTESTRUNNER qmltestrunner PATHS /usr/lib/qt6/bin /usr/lib64/qt6/bin REQUIRED)
add_test(NAME media-fallback
    COMMAND "${QMLTESTRUNNER}" -input "${AERIAL_LOCK_SOURCE}/Tests/media-fallback-fault.qml")
set_tests_properties(media-fallback PROPERTIES ENVIRONMENT
    "LD_PRELOAD=$<TARGET_FILE:full-caller-faults>;AERIAL_TEST_FULL_CALLER_FAULT=core-create;QT_QPA_PLATFORM=offscreen")
