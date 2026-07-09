program unit_test

  use env_mo

  implicit none

  type(env_ty)   :: env
  character(255) :: path, cstr
  integer        :: ival, n, u
  real           :: rval
  logical        :: lval
  integer        :: nfail = 0

  print *, '===== fortran-env unit test ====='

  ! --- 1. UNSET -> one polymorphic get() keeps the pre-set default (any type) ---
  cstr = 'fallback' ; call env%get ( 'ENV_MO_UNSET', cstr )
  call check_c ( trim(cstr), 'fallback', 'get character keeps default when unset' )
  ival = 7          ; call env%get ( 'ENV_MO_UNSET', ival )
  call check_i ( ival, 7, 'get integer keeps default when unset' )
  rval = 2.5        ; call env%get ( 'ENV_MO_UNSET', rval )
  call check_r ( rval, 2.5, 'get real keeps default when unset' )
  lval = .true.     ; call env%get ( 'ENV_MO_UNSET', lval )
  call check_l ( lval, .true., 'get logical keeps default when unset' )
  call check_l ( env%is_set ( 'ENV_MO_UNSET' ), .false., 'is_set = F when unset' )

  ! explicit-default form
  call env%get ( 'ENV_MO_UNSET', ival, 99 )
  call check_i ( ival, 99, 'get integer uses explicit default when unset' )

  path = '/srv/data/compiled-default'
  call env%override ( path, 'ENV_MO_UNSET' )
  call check_c ( trim(path), '/srv/data/compiled-default', 'override no-op when unset' )

  ! --- 2. SET variables (provided by ctest ENVIRONMENT in test/CMakeLists.txt) ---
  cstr = ''      ; call env%get ( 'ENV_MO_STR',  cstr )
  call check_c ( trim(cstr), 'hello', 'get character when set' )
  ival = 0       ; call env%get ( 'ENV_MO_INT',  ival )
  call check_i ( ival, 42, 'get integer when set' )
  rval = 0.0     ; call env%get ( 'ENV_MO_REAL', rval )
  call check_r ( rval, 3.14, 'get real when set' )
  lval = .false. ; call env%get ( 'ENV_MO_BOOL', lval )
  call check_l ( lval, .true., 'get logical when set (T)' )
  call check_l ( env%is_set ( 'ENV_MO_STR' ), .true., 'is_set = T when set' )

  path = '/srv/data/compiled-default'
  call env%override ( path, 'ENV_MO_PATH' )
  call check_c ( trim(path), '/srv/data/tkd-wx-jma-amedas', 'override applies when set' )

  ! --- 3. require: returns a present var (a missing one would error stop) ---
  call check_c ( env%require ( 'ENV_MO_STR' ), 'hello', 'require returns when set' )

  ! --- 4. mangle_key: '%' and array subscripts -> '_' ---
  call check_c ( env%mangle_key ( 'NML%DIR%WTHR_OBS' ), 'NML_DIR_WTHR_OBS', 'mangle %' )
  call check_c ( env%mangle_key ( 'NML%N(1)%TGTS' ),    'NML_N_1_TGTS',     'mangle %(n)%' )
  call check_c ( env%mangle_key ( 'AREAS(1,2)' ),       'AREAS_1_2',        'mangle (i,j)' )

  ! --- 5. set: env write -> get roundtrip ---
  call env%set ( 'ENV_MO_ROUNDTRIP', '/some/path' )
  cstr = '' ; call env%get ( 'ENV_MO_ROUNDTRIP', cstr )
  call check_c ( trim(cstr), '/some/path', 'set + get roundtrip' )

  ! --- 6. load_namelist: file -> env vars, keys mangled, values de-quoted ---
  open ( newunit = u, file = 'env_mo_test.nml', status = 'replace', action = 'write' )
  write ( u, '(a)' ) '&config'
  write ( u, '(a)' ) '  NML%DIR%WTHR_OBS = "/srv/data/jma=amedas",   ! obs store'
  write ( u, '(a)' ) '  NML%N(1)%TGTS    = 24'
  write ( u, '(a)' ) '  NML%SHRINK%FLAG  = T'
  write ( u, '(a)' ) '/'
  close ( u )
  n = env%load_namelist ( 'env_mo_test.nml' )
  call check_i ( n, 3, 'load_namelist sets 3 vars' )
  cstr = '' ; call env%get ( 'NML_DIR_WTHR_OBS', cstr )
  call check_c ( trim(cstr), '/srv/data/jma=amedas', 'namelist % path (comment/comma stripped)' )
  ival = 0  ; call env%get ( 'NML_N_1_TGTS', ival )
  call check_i ( ival, 24, 'namelist array-index integer' )
  lval = .false. ; call env%get ( 'NML_SHRINK_FLAG', lval )
  call check_l ( lval, .true., 'namelist logical' )

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
