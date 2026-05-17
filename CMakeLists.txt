cmake_minimum_required(VERSION 3.10)
project(VoYahScheduler VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wall -Wextra -Wno-unused-result -pthread")

# --- Public include directories ---
target_include_directories(${PROJECT_NAME} INTERFACE
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:include>
)

# --- Sources ---
add_executable(${PROJECT_NAME}
    ${CMAKE_CURRENT_SOURCE_DIR}/src/scheduler.cpp
)
target_include_directories(${PROJECT_NAME} PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

# --- Install ---
install(TARGETS ${PROJECT_NAME} DESTINATION bin)
install(DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/include/ DESTINATION include)
install(DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/docs/ DESTINATION share/doc/voyah-scheduler)

# --- Testing ---
enable_testing()
find_package(Bash)
if(BASH_FOUND)
    foreach(script IN LISTS TEST_SCRIPTS)
        get_filename_component(name ${script} NAME)
        add_test(NAME "shell/${name}" COMMAND ${BASH_EXECUTABLE} ${script} ${PROJECT_BINARY_DIR}/${PROJECT_NAME})
    endforeach()
endif()
