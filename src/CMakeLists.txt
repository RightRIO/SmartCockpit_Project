# Scheduler source target
add_executable(voyah_scheduler
    ${CMAKE_CURRENT_SOURCE_DIR}/src/scheduler.cpp
)
target_include_directories(voyah_scheduler PRIVATE
    ${CMAKE_SOURCE_DIR}/include
)
target_compile_features(voyah_scheduler PRIVATE cxx_std_17)
