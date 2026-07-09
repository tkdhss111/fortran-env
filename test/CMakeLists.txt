set ( EXE unit_test )
set ( SRCS ./unit_test.f90 ../src/env_mo.f90 )

set ( CMAKE_Fortran_FLAGS
  "-ffree-line-length-none -fcoarray=single")
set ( CMAKE_Fortran_FLAGS_DEBUG
  "-Ddebug -O0 -fbounds-check -fbacktrace -Wall -Wno-uninitialized -Wno-maybe-uninitialized ${CMAKE_Fortran_FLAGS}" )

add_executable ( ${EXE} ${SRCS} )
add_test ( NAME ${EXE} COMMAND ${EXE} WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR} )

# env_mo reads the environment, so the test's "set" cases are supplied here.
set_tests_properties ( ${EXE} PROPERTIES ENVIRONMENT
  "ENV_MO_STR=hello;ENV_MO_INT=42;ENV_MO_REAL=3.14;ENV_MO_BOOL=T;ENV_MO_PATH=/var/data/app" )
