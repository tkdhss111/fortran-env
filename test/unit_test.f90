program unit_test

  use env_mo

  implicit none

  type(env_ty)    :: env
  character(255)  :: path, cstr
  character(4096) :: line
  integer         :: ival, n, u, ios
  real            :: rval
  real(kind(1d0)) :: dval
  logical         :: lval, found, secret_leaked
  integer         :: nfail = 0

  print *, '===== fortran-env unit test ====='

  ! --- 1. UNSET -> one polymorphic get() keeps the pre-set default (any type) ---
  cstr = 'fallback' ; call env%get ( 'ENV_MO_UNSET', cstr )
  call check_c ( trim(cstr), 'fallback', 'get character keeps default when unset' )
  ival = 7          ; call env%get ( 'ENV_MO_UNSET', ival )
  call check_i ( ival, 7, 'get integer keeps default when unset' )
  rval = 2.5        ; call env%get ( 'ENV_MO_UNSET', rval )
  call check_r ( rval, 2.5, 'get real keeps default when unset' )
  dval = 9.0d0      ; call env%get ( 'ENV_MO_UNSET', dval )
  call check_r ( real(dval), 9.0, 'get double keeps default when unset' )
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
  dval = 0.0d0   ; call env%get ( 'ENV_MO_REAL', dval )
  call check_r ( real(dval), 3.14, 'get double when set' )
  lval = .false. ; call env%get ( 'ENV_MO_BOOL', lval )
  call check_l ( lval, .true., 'get logical when set (T)' )
  call check_l ( env%is_set ( 'ENV_MO_STR' ), .true., 'is_set = T when set' )

  path = '/srv/data/compiled-default'
  call env%override ( path, 'ENV_MO_PATH' )
  call check_c ( trim(path), '/srv/data/tkd-wx-jma-amedas', 'override applies when set' )

  ! bad parse -> keep default (unchanged)
  ival = 5 ; call env%get ( 'ENV_MO_STR', ival )   ! 'hello' is not an integer
  call check_i ( ival, 5, 'get integer keeps default on parse error' )

  ! --- 3. require: returns a present var (a missing one would error stop) ---
  call check_c ( env%require ( 'ENV_MO_STR' ), 'hello', 'require returns when set' )

  ! --- 4. mangle_key: '%' and array subscripts -> '_' ---
  call check_c ( env%mangle_key ( 'NML%DIR%WTHR_OBS' ), 'NML_DIR_WTHR_OBS', 'mangle a%b%c' )
  call check_c ( env%mangle_key ( 'NML%N(1)%TGTS' ),    'NML_N_1_TGTS',     'mangle %(n)%' )
  call check_c ( env%mangle_key ( 'AREAS(1,2)' ),       'AREAS_1_2',        'mangle (i,j)' )
  call check_c ( env%mangle_key ( 'X(3)' ),             'X_3',              'mangle trailing (i)' )
  call check_c ( env%mangle_key ( 'FLAT' ),             'FLAT',             'mangle no-op' )

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

  ! --- 7. save: live environment -> .env file, prefix-filtered ---
  call env%set ( 'ENV_MO_SECRET_KEY', 'do-not-leak' )   ! a non-NML_ var that must NOT be written
  n = env%save ( 'env_mo_out.env', 'NML_' )
  call check_i ( n, 3, 'save writes exactly the 3 NML_ vars' )
  found = .false. ; secret_leaked = .false.
  open ( newunit = u, file = 'env_mo_out.env', status = 'old', action = 'read' )
  do
    read ( u, '(a)', iostat = ios ) line
    if ( ios /= 0 ) exit
    if ( trim(line) == 'NML_DIR_WTHR_OBS=/srv/data/jma=amedas' ) found = .true.
    if ( index ( line, 'ENV_MO_SECRET_KEY' ) > 0 )               secret_leaked = .true.
  end do
  close ( u )
  call check_l ( found, .true., 'save wrote the exact KEY=VALUE line' )
  call check_l ( secret_leaked, .false., 'prefix filter keeps non-matching (secret) vars out' )

  ! --- 8. load: .env file -> env vars (inverse of save; keys used verbatim) ---
  open ( newunit = u, file = 'env_mo_in.env', status = 'replace', action = 'write' )
  write ( u, '(a)' ) '# a comment line'
  write ( u, '(a)' ) '! also a comment'
  write ( u, '(a)' ) ''
  write ( u, '(a)' ) 'DIR_TKD_DATA=/srv/data'
  write ( u, '(a)' ) 'export ENV_MO_N=8'
  write ( u, '(a)' ) 'QUOTED_VAL="hello world"'
  write ( u, '(a)' ) 'BAD-NAME=nope'        ! hyphen -> not a valid env name, skipped
  write ( u, '(a)' ) '9LEADING=nope'        ! leading digit -> skipped
  close ( u )
  n = env%load ( 'env_mo_in.env' )
  call check_i ( n, 3, 'load sets 3 valid vars (comments/blank/bad-name skipped)' )
  cstr = '' ; call env%get ( 'DIR_TKD_DATA', cstr )
  call check_c ( trim(cstr), '/srv/data', 'load plain KEY=VALUE' )
  ival = 0  ; call env%get ( 'ENV_MO_N', ival )
  call check_i ( ival, 8, 'load strips `export ` and parses int' )
  cstr = '' ; call env%get ( 'QUOTED_VAL', cstr )
  call check_c ( trim(cstr), 'hello world', 'load de-quotes a "..." value' )

  ! --- 9. save -> load round trip (line count integrity) ---
  call env%set ( 'RT_A', 'alpha' )
  call env%set ( 'RT_B', 'beta' )
  n = env%save ( 'env_mo_rt.env', 'RT_' )
  call check_i ( n, 2, 'round trip: save wrote 2 RT_ vars' )
  n = env%load ( 'env_mo_rt.env' )
  call check_i ( n, 2, 'round trip: load read 2 RT_ vars back' )

  ! --- 10. save with no prefix dumps every tracked var (all we set/loaded) ---
  n = env%save ( 'env_mo_all.env' )
  call check_l ( n >= 8, .true., 'save without prefix dumps all tracked vars' )

  ! --- 11. validation: is_name / bad_char detect unpermitted characters ---
  call check_l ( env%is_name ( 'DIR_TKD_DATA' ), .true.,  'is_name accepts a valid name' )
  call check_l ( env%is_name ( '_PRIVATE' ),     .true.,  'is_name accepts leading underscore' )
  call check_l ( env%is_name ( '9LEADING' ),     .false., 'is_name rejects a leading digit' )
  call check_l ( env%is_name ( 'A-B' ),          .false., 'is_name rejects a hyphen' )
  call check_l ( env%is_name ( '' ),             .false., 'is_name rejects empty' )
  call check_i ( env%bad_char ( 'OK_NAME_1' ),        0, 'bad_char: clean name -> 0' )
  call check_i ( env%bad_char ( 'AB*CD' ),            3, 'bad_char: flags * at position 3' )
  call check_i ( env%bad_char ( 'abc', 'abcdef' ),    0, 'bad_char: custom allowed set, clean' )
  call check_i ( env%bad_char ( 'abz', 'abcdef' ),    3, 'bad_char: custom allowed set, z at 3' )

  ! --- 12. expand: $VAR / ${VAR} against the environment, unset -> '' ---
  call env%set ( 'EXP_BASE', '/srv/data' )
  call check_c ( env%expand ( '$EXP_BASE/sub' ),   '/srv/data/sub', 'expand $VAR' )
  call check_c ( env%expand ( '${EXP_BASE}/sub' ), '/srv/data/sub', 'expand ${VAR}' )
  call check_c ( env%expand ( '$NOPE_XYZ/tail' ),  '/tail',         'expand undefined $VAR -> empty' )
  call check_c ( env%expand ( 'cost is $5' ),      'cost is $5',    'literal $ (not a ref) kept' )

  ! --- 13. load with expansion: later lines resolve earlier ones (source order) ---
  open ( newunit = u, file = 'env_mo_exp.env', status = 'replace', action = 'write' )
  write ( u, '(a)' ) 'EXP_ROOT=/srv/data'
  write ( u, '(a)' ) 'EXP_LEAF=$EXP_ROOT/tkd-wx'
  write ( u, '(a)' ) 'EXP_MISS=${NOPE_ABC}/x'
  close ( u )
  n = env%load ( 'env_mo_exp.env' )
  call check_i ( n, 3, 'load with expansion: 3 vars' )
  cstr = '' ; call env%get ( 'EXP_LEAF', cstr )
  call check_c ( trim(cstr), '/srv/data/tkd-wx', 'load expands $VAR to a prior var' )
  cstr = '' ; call env%get ( 'EXP_MISS', cstr )
  call check_c ( trim(cstr), '/x', 'load expands undefined ${VAR} to empty' )

  ! --- 14. unset: unsetenv + untrack ---
  call env%set ( 'UNSET_ME', 'x' )
  call check_l ( env%is_set ( 'UNSET_ME' ), .true.,  'set before unset' )
  call env%unset ( 'UNSET_ME' )
  call check_l ( env%is_set ( 'UNSET_ME' ), .false., 'unset removes the var' )
  n = env%save ( 'env_mo_unset.env', 'UNSET_' )
  call check_i ( n, 0, 'unset also untracks (save skips it)' )

  ! --- 15. save_sh: runnable `export` script, sh-safe quoting ---
  call env%set ( 'SH_A', 'plain' )
  call env%set ( 'SH_B', "it's quoted" )              ! embedded single quote
  n = env%save_sh ( 'env_mo_set.sh', 'SH_' )
  call check_i ( n, 2, 'save_sh writes 2 SH_ vars' )
  found = .false. ; secret_leaked = .false.           ! reuse: secret_leaked = "found SH_B escaped line"
  open ( newunit = u, file = 'env_mo_set.sh', status = 'old', action = 'read' )
  do
    read ( u, '(a)', iostat = ios ) line
    if ( ios /= 0 ) exit
    if ( trim(line) == "export SH_A='plain'" )          found = .true.
    if ( trim(line) == "export SH_B='it'\''s quoted'" ) secret_leaked = .true.
  end do
  close ( u )
  call check_l ( found,         .true., 'save_sh wrote a plain export line' )
  call check_l ( secret_leaked, .true., 'save_sh escaped an embedded single quote' )

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
