program unit_test

  use env_mo

  implicit none

  type(env_ty)   :: env
  character(255) :: path
  integer        :: nfail = 0

  print *, '===== fortran-env unit test ====='

  ! --- 1. UNSET variable -> compiled default / no-op (needs no environment) ---
  call check_c ( env%get_character ( 'ENV_MO_UNSET', 'fallback' ), 'fallback', 'get_character default' )
  call check_i ( env%get_integer   ( 'ENV_MO_UNSET', 7 ),          7,          'get_integer default'   )
  call check_r ( env%get_real      ( 'ENV_MO_UNSET', 2.5 ),        2.5,        'get_real default'      )
  call check_l ( env%get_logical   ( 'ENV_MO_UNSET', .true. ),     .true.,     'get_logical default'   )
  call check_l ( env%is_set        ( 'ENV_MO_UNSET' ),             .false.,    'is_set = F when unset' )

  path = '/srv/data/compiled-default'
  call env%override ( path, 'ENV_MO_UNSET' )
  call check_c ( trim(path), '/srv/data/compiled-default', 'override no-op when unset' )

  ! --- 2. SET variables (provided by ctest ENVIRONMENT in test/CMakeLists.txt) ---
  call check_c ( env%get_character ( 'ENV_MO_STR' ),           'hello', 'get_character set'   )
  call check_i ( env%get_integer   ( 'ENV_MO_INT',  0 ),       42,      'get_integer set'     )
  call check_r ( env%get_real      ( 'ENV_MO_REAL', 0.0 ),     3.14,    'get_real set'        )
  call check_l ( env%get_logical   ( 'ENV_MO_BOOL', .false. ), .true.,  'get_logical set (T)' )
  call check_l ( env%is_set        ( 'ENV_MO_STR' ),           .true.,  'is_set = T when set' )

  path = '/srv/data/compiled-default'
  call env%override ( path, 'ENV_MO_PATH' )
  call check_c ( trim(path), '/srv/data/tkd-wx-jma-amedas', 'override applies when set' )

  ! --- 3. require: returns a present var (a missing one would error stop) ---
  call check_c ( env%require ( 'ENV_MO_STR' ), 'hello', 'require returns when set' )

  print *, '================================='
  if ( nfail == 0 ) then
    print *, 'ALL TESTS PASSED'
  else
    print *, nfail, ' TEST(S) FAILED'
    error stop 1
  end if

contains

  subroutine check_c ( got, want, label )
    character(*), intent(in) :: got, want, label
    if ( got == want ) then
      print *, 'PASS  '//label
    else
      print *, 'FAIL  '//label//'  got=['//got//']  want=['//want//']'
      nfail = nfail + 1
    end if
  end subroutine

  subroutine check_i ( got, want, label )
    integer,      intent(in) :: got, want
    character(*), intent(in) :: label
    if ( got == want ) then
      print *, 'PASS  '//label
    else
      print *, 'FAIL  '//label//'  got=', got, ' want=', want
      nfail = nfail + 1
    end if
  end subroutine

  subroutine check_r ( got, want, label )
    real,         intent(in) :: got, want
    character(*), intent(in) :: label
    if ( abs ( got - want ) < 1.0e-5 ) then
      print *, 'PASS  '//label
    else
      print *, 'FAIL  '//label//'  got=', got, ' want=', want
      nfail = nfail + 1
    end if
  end subroutine

  subroutine check_l ( got, want, label )
    logical,      intent(in) :: got, want
    character(*), intent(in) :: label
    if ( got .eqv. want ) then
      print *, 'PASS  '//label
    else
      print *, 'FAIL  '//label//'  got=', got, ' want=', want
      nfail = nfail + 1
    end if
  end subroutine

end program
