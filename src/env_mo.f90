! Thin environment-variable tool for the tkd fleet. One-concept tool, same shape
! as cli_mo / logger_mo. Portable across gfortran and ifx: pure Fortran except a
! single libc `setenv` binding (the only way to *write* the environment from
! Fortran). Resolves data-path registry variables
! (/srv/data/tkd-config/data-paths.env, injected by a quadlet EnvironmentFile or
! `source`) with a compiled fallback, via ONE polymorphic getter — no get_<type>.
!
! It can also INGEST a Fortran namelist file, setting each `KEY = VALUE` as an env
! var. Env names can't hold `%` or `()`, so the key is mangled to a flat name —
! every structural separator becomes `_`:
!     a%b     ->  a_b        ( `%` derived-type component  -> `_` )
!     a(1)    ->  a_1        ( `(i)` array subscript        -> `_i` )
!     a(1,2)  ->  a_1_2      ( `(i,j)` multi-dim subscript  -> `_i_j` )
!     NML%DIR%WTHR_OBS  ->  NML_DIR_WTHR_OBS
!     NML%N(1)%TGTS     ->  NML_N_1_TGTS
!
! save() writes back out the variables env_mo has set (via set / load /
! load_namelist) as a `.env` file — so what you loaded round-trips, and ambient
! secrets you never touched (API keys, etc.) are never dumped.
!
! Usage:
!   use env_mo
!   type(env_ty)   :: env
!   integer        :: n   = 1
!   real           :: x   = 90.0
!   character(255) :: dir = '/srv/data/default'
!   call env%get ( 'FOR_COARRAY_NUM_IMAGES', n )         ! any scalar type; n kept if unset
!   call env%get ( 'HALFLIFE_DAYS', x, 90.0 )            ! explicit default also accepted
!   call env%override ( dir, 'DIR_TKD_WX_JMA_AMEDAS' )   ! registry no-op override (get alias)
!   n   = env%load_namelist ( 'config.nml' )             ! namelist file -> env vars
!   n   = env%load ( 'data-paths.env' )                  ! .env file -> env vars ($VAR expanded)
!   n   = env%save ( 'out.env', 'DIR_TKD_' )             ! set/loaded vars -> .env (prefix-filtered)
!   n   = env%save_sh ( 'setenv.sh', 'DIR_TKD_' )        ! runnable `export` script (source it)
!   n   = env%clear_sh ( 'clearenv.sh', 'DIR_TKD_' )     ! runnable `unset` script (source it to clear)
!   call env%unset ( 'TMP_VAR' )                         ! unsetenv + untrack
!   if ( .not. env%is_name ( key ) ) ...                 ! validate an env-var name
!   key = env%require ( 'OPENMETEO_APIKEY' )             ! required string, else error stop

module env_mo

  use, intrinsic :: iso_c_binding, only : c_char, c_int, c_null_char

  implicit none

  private
  public :: env_ty

  integer, parameter :: MAXLEN  = 4096         ! generous: long store paths, API keys
  integer, parameter :: MAXNAME = 255          ! tracked env-var name length
  integer, parameter :: dp      = kind(1.0d0)  ! double-precision get() targets

  ! Permitted characters in a POSIX environment-variable name.
  character(*), parameter :: NAME_HEAD = &
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_'
  character(*), parameter :: NAME_BODY = NAME_HEAD//'0123456789'

  ! Names this module has set — the set save() writes back out. Module-scope
  ! (saved) state; single-threaded use, one coarray image per process.
  character(MAXNAME), allocatable, save :: g_names(:)
  integer,                         save :: g_count = 0

  ! libc setenv/unsetenv — the only portable way to write the environment from Fortran.
  interface
    function c_setenv ( name, value, overwrite ) bind(C, name = 'setenv') result ( r )
      import :: c_char, c_int
      character(kind=c_char), intent(in) :: name(*), value(*)
      integer(c_int), value :: overwrite
      integer(c_int)        :: r
    end function
    function c_unsetenv ( name ) bind(C, name = 'unsetenv') result ( r )
      import :: c_char, c_int
      character(kind=c_char), intent(in) :: name(*)
      integer(c_int)                     :: r
    end function
  end interface

  type env_ty
  contains
    procedure, nopass :: get           => env_get            ! polymorphic getter (any scalar type)
    procedure, nopass :: override      => env_override       ! in-place registry override (get alias)
    procedure, nopass :: is_set        => env_is_set
    procedure, nopass :: is_name       => env_is_name        ! valid env-var name?
    procedure, nopass :: bad_char      => env_bad_char       ! first unpermitted char position (0=ok)
    procedure, nopass :: require       => env_require        ! required string, else error stop
    procedure, nopass :: set           => env_set            ! setenv one variable (tracked)
    procedure, nopass :: unset         => env_unset          ! unsetenv + untrack
    procedure, nopass :: expand        => env_expand         ! $VAR / ${VAR} -> value ('' if unset)
    procedure, nopass :: mangle_key    => env_mangle_key     ! namelist key -> env name
    procedure, nopass :: load_namelist => env_load_namelist  ! namelist file -> env vars
    procedure, nopass :: load          => env_load           ! .env file  -> env vars
    procedure, nopass :: save          => env_save           ! set/loaded vars -> .env file
    procedure, nopass :: save_sh       => env_save_sh        ! set/loaded vars -> runnable export script
    procedure, nopass :: clear_sh      => env_clear_sh       ! set/loaded vars -> runnable unset script
  end type

contains

  ! True when $name is present and non-empty.
  logical function env_is_set ( name ) result ( ok )
    character(*), intent(in) :: name
    character(MAXLEN) :: val
    integer :: ln, st
    call get_environment_variable ( name, val, length = ln, status = st )
    ok = ( st == 0 .and. ln > 0 )
  end function

  ! Raw $name as a trimmed string, or '' when unset. Internal primitive.
  function env_raw ( name ) result ( str )
    character(*), intent(in)  :: name
    character(:), allocatable :: str
    character(MAXLEN) :: val
    integer :: ln, st
    call get_environment_variable ( name, val, length = ln, status = st )
    if ( st == 0 .and. ln > 0 ) then
      str = trim(val)
    else
      str = ''
    end if
  end function

  ! Valid POSIX env-var name: first char a letter or '_', the rest also digits.
  logical function env_is_name ( name ) result ( ok )
    character(*), intent(in) :: name
    integer :: n
    n  = len_trim(name)
    ok = .false.
    if ( n == 0 )                            return
    if ( verify ( name(1:1), NAME_HEAD ) /= 0 ) return
    if ( verify ( name(1:n), NAME_BODY ) /= 0 ) return
    ok = .true.
  end function

  ! Detect unpermitted characters: position of the first char of `str` NOT in
  ! `allowed` (0 = all permitted). With no `allowed`, checks the env-name charset
  ! (letters, digits, '_'). Handy to validate a config value before set/save.
  integer function env_bad_char ( str, allowed ) result ( pos )
    character(*), intent(in)           :: str
    character(*), intent(in), optional :: allowed
    if ( present(allowed) ) then
      pos = verify ( trim(str), allowed )
    else
      pos = verify ( trim(str), NAME_BODY )
    end if
  end function

  ! ONE getter for every scalar type. Fetch $name into `val` (character / integer
  ! / real / double / logical). When the variable is unset or unparseable, `val`
  ! keeps `default` if given, else its incoming value — so pre-setting `val` to a
  ! compiled default and calling get(name, val) works too. This replaces the old
  ! get_character / get_integer / get_real / get_logical family.
  subroutine env_get ( name, val, default )
    character(*), intent(in)              :: name
    class(*),     intent(inout)           :: val
    class(*),     intent(in),    optional :: default
    character(:), allocatable :: s
    logical  :: isset
    integer  :: ios, itmp
    real     :: rtmp
    real(dp) :: dtmp
    s     = env_raw ( name )
    isset = len_trim(s) > 0
    select type ( v => val )
    type is ( character(*) )
      if ( isset ) then
        v = s
      else if ( present(default) ) then
        select type ( d => default ) ; type is ( character(*) ) ; v = d ; end select
      end if
    type is ( integer )
      if ( isset ) then
        read ( s, *, iostat = ios ) itmp ; if ( ios == 0 ) v = itmp
      else if ( present(default) ) then
        select type ( d => default ) ; type is ( integer ) ; v = d ; end select
      end if
    type is ( real )
      if ( isset ) then
        read ( s, *, iostat = ios ) rtmp ; if ( ios == 0 ) v = rtmp
      else if ( present(default) ) then
        select type ( d => default )
        type is ( real )     ; v = d
        type is ( real(dp) ) ; v = real(d)
        type is ( integer )  ; v = real(d)
        end select
      end if
    type is ( real(dp) )
      if ( isset ) then
        read ( s, *, iostat = ios ) dtmp ; if ( ios == 0 ) v = dtmp
      else if ( present(default) ) then
        select type ( d => default )
        type is ( real(dp) ) ; v = d
        type is ( real )     ; v = real(d, dp)
        type is ( integer )  ; v = real(d, dp)
        end select
      end if
    type is ( logical )
      if ( isset ) then
        select case ( s(1:1) )
        case ( 'T', 't', '1', 'Y', 'y' ) ; v = .true.
        case ( 'F', 'f', '0', 'N', 'n' ) ; v = .false.
        end select
      else if ( present(default) ) then
        select type ( d => default ) ; type is ( logical ) ; v = d ; end select
      end if
    end select
  end subroutine

  ! Registry no-op override: overwrite `val` in place from $name when set, else
  ! keep the caller's compiled default. `val` may be any scalar type. get alias.
  subroutine env_override ( val, name )
    class(*),     intent(inout) :: val
    character(*), intent(in)    :: name
    call env_get ( name, val )
  end subroutine

  ! Required variable: return it, or print + error stop if unset (secrets / critical config).
  function env_require ( name ) result ( str )
    character(*), intent(in)  :: name
    character(:), allocatable :: str
    if ( env_is_set ( name ) ) then
      str = env_raw ( name )
    else
      write ( *, '(a)' ) 'env_mo: FATAL required environment variable not set: '//trim(name)
      error stop 1
    end if
  end function

  ! Remember a name (deduped) so save() can write it back out later.
  subroutine env_track ( name )
    character(*), intent(in) :: name
    character(MAXNAME), allocatable :: tmp(:)
    integer :: i, cap
    do i = 1, g_count
      if ( g_names(i) == name ) return                 ! already tracked
    end do
    if ( .not. allocated ( g_names ) ) allocate ( g_names(16) )
    cap = size ( g_names )
    if ( g_count == cap ) then                         ! grow x2
      allocate ( tmp(2*cap) )
      tmp(1:cap) = g_names
      call move_alloc ( tmp, g_names )
    end if
    g_count = g_count + 1
    g_names(g_count) = name
  end subroutine

  ! Set (or overwrite) $name in the current process (inherited by child processes)
  ! and remember it for save(). Names that aren't valid identifiers are ignored.
  subroutine env_set ( name, value )
    character(*), intent(in) :: name, value
    integer(c_int) :: r
    if ( .not. env_is_name ( name ) ) return
    r = c_setenv ( trim(name)//c_null_char, trim(value)//c_null_char, 1_c_int )
    call env_track ( trim(name) )
  end subroutine

  ! Remove $name from the environment and stop tracking it (the set/save pair).
  subroutine env_unset ( name )
    character(*), intent(in) :: name
    integer(c_int) :: r
    integer :: i, j
    r = c_unsetenv ( trim(name)//c_null_char )
    j = 0
    do i = 1, g_count                                ! compact the tracked list
      if ( trim(g_names(i)) == trim(name) ) cycle
      j = j + 1
      g_names(j) = g_names(i)
    end do
    g_count = j
  end subroutine

  ! Expand $VAR and ${VAR} references against the current environment; an unset
  ! variable expands to '' (like `source`). A '$' that doesn't start a valid
  ! reference is kept literally. Applied to values by load / load_namelist.
  function env_expand ( str ) result ( out )
    character(*), intent(in)  :: str
    character(:), allocatable :: out
    integer :: i, n, j
    n = len ( str )
    out = ''
    i = 1
    do while ( i <= n )
      if ( str(i:i) == '$' .and. i < n ) then
        if ( str(i+1:i+1) == '{' ) then                          ! ${VAR}
          j = index ( str(i+2:), '}' )
          if ( j > 0 ) then
            out = out // env_raw ( str(i+2:i+j) )
            i = i + j + 2
            cycle
          end if
        else if ( verify ( str(i+1:i+1), NAME_HEAD ) == 0 ) then ! $VAR
          j = i + 1
          do while ( j <= n )
            if ( verify ( str(j:j), NAME_BODY ) /= 0 ) exit
            j = j + 1
          end do
          out = out // env_raw ( str(i+1:j-1) )
          i = j
          cycle
        end if
      end if
      out = out // str(i:i)
      i = i + 1
    end do
  end function

  ! Fortran namelist key -> env-var name: '%' and array subscripts collapse to '_'.
  !   NML%DIR%WTHR_OBS -> NML_DIR_WTHR_OBS ; NML%N(1)%TGTS -> NML_N_1_TGTS ; A(1,2) -> A_1_2
  function env_mangle_key ( key ) result ( name )
    character(*), intent(in)  :: key
    character(:), allocatable :: name
    integer :: i
    name = ''
    do i = 1, len_trim(key)
      select case ( key(i:i) )
      case ( '%', '(', ',' )                       ! component sep / subscript -> '_'
        if ( len(name) > 0 ) then
          if ( name(len(name):len(name)) /= '_' ) name = name//'_'
        end if
      case ( ')', ' ' )                            ! drop closing subscript / spaces
        continue
      case default
        name = name//key(i:i)
      end select
    end do
    do while ( len(name) > 0 )                     ! trim a trailing '_' (from a closing subscript)
      if ( name(len(name):len(name)) /= '_' ) exit
      name = name(1:len(name)-1)
    end do
  end function

  ! Ingest a Fortran namelist FILE: each `KEY = VALUE` line becomes an env var
  ! named mangle_key(KEY). De-quotes strings, drops a trailing comma or inline
  ! `! comment`, and skips &group / '/' / blank / comment / malformed-name lines.
  ! Optional `prefix` is prepended to every env name. Returns the number set.
  function env_load_namelist ( file, prefix ) result ( nset )
    character(*), intent(in)           :: file
    character(*), intent(in), optional :: prefix
    integer :: nset, u, ios, eq, j
    character(MAXLEN)         :: line
    character(:), allocatable :: key, val, name
    character                 :: q
    nset = 0
    open ( newunit = u, file = file, status = 'old', action = 'read', iostat = ios )
    if ( ios /= 0 ) return
    do
      read ( u, '(a)', iostat = ios ) line
      if ( ios /= 0 ) exit
      line = adjustl ( line )
      if ( len_trim(line) == 0 )           cycle
      if ( scan ( line(1:1), '!&/' ) > 0 ) cycle       ! comment / group open / close
      eq = index ( line, '=' )
      if ( eq <= 1 ) cycle
      key = trim ( adjustl ( line(1:eq-1) ) )
      val = adjustl ( line(eq+1:) )
      if ( len_trim(val) == 0 ) cycle
      if ( val(1:1) == '"' .or. val(1:1) == "'" ) then  ! quoted -> inside the quotes
        q = val(1:1)
        j = index ( val(2:), q )
        if ( j > 0 ) then ; val = val(2:j) ; else ; val = trim ( val(2:) ) ; end if
      else                                              ! unquoted -> cut at comma / comment
        j = scan ( val, ',!' )
        if ( j > 0 ) val = val(1:j-1)
        val = trim ( adjustl ( val ) )
      end if
      val  = env_expand ( val )                        ! $VAR / ${VAR} against vars set so far
      name = env_mangle_key ( key )
      if ( present(prefix) ) name = prefix//name
      if ( .not. env_is_name ( name ) ) cycle          ! skip keys that don't mangle to a valid name
      call env_set ( name, val )
      nset = nset + 1
    end do
    close ( u )
  end function

  ! Read a plain `.env` file (`KEY=VALUE` per line) and set each variable — the
  ! inverse of save. Skips blank / `#` / `!` comment / invalid-name lines, strips
  ! an optional leading `export `, and de-quotes a fully "..."/'...'-quoted value.
  ! Returns the number of variables set.
  function env_load ( file ) result ( nset )
    character(*), intent(in) :: file
    integer :: nset, u, ios, eq
    character(MAXLEN)         :: line
    character(:), allocatable :: key, val
    character                 :: q
    nset = 0
    open ( newunit = u, file = file, status = 'old', action = 'read', iostat = ios )
    if ( ios /= 0 ) return
    do
      read ( u, '(a)', iostat = ios ) line
      if ( ios /= 0 ) exit
      line = adjustl ( line )
      if ( len_trim(line) == 0 )          cycle
      if ( scan ( line(1:1), '#!' ) > 0 ) cycle        ! comment line
      if ( line(1:7) == 'export ' ) line = adjustl ( line(8:) )   ! optional export prefix
      eq = index ( line, '=' )
      if ( eq <= 1 ) cycle
      key = trim ( adjustl ( line(1:eq-1) ) )
      val = trim ( adjustl ( line(eq+1:) ) )
      if ( len(val) >= 2 ) then                        ! de-quote "..." / '...'
        q = val(1:1)
        if ( ( q == '"' .or. q == "'" ) .and. val(len(val):len(val)) == q ) &
          val = val(2:len(val)-1)
      end if
      val = env_expand ( val )                          ! $VAR / ${VAR} against vars set so far
      if ( .not. env_is_name ( key ) ) cycle           ! skip malformed keys
      call env_set ( key, val )
      nset = nset + 1
    end do
    close ( u )
  end function

  ! Prefix filter shared by the writers: keep `nm` when `pfx` is empty, or `pfx`
  ! is a prefix of `nm`.
  logical function env_keep ( nm, pfx ) result ( keep )
    character(*), intent(in) :: nm, pfx
    keep = .true.
    if ( len(pfx) > 0 ) then
      keep = .false.
      if ( len(nm) >= len(pfx) ) keep = ( nm(1:len(pfx)) == pfx )
    end if
  end function

  ! Write the variables env_mo has set/loaded to `file` in .env format — one
  ! `KEY=VALUE` per line, exactly what a quadlet EnvironmentFile / podman
  ! --env-file / `source` consume. With `prefix`, only names starting with it are
  ! written. Values are read live, so overwrites are reflected. Returns the count.
  function env_save ( file, prefix ) result ( nwritten )
    character(*), intent(in)           :: file
    character(*), intent(in), optional :: prefix
    integer :: nwritten, u, i, ios
    character(:), allocatable :: pfx, nm, val
    nwritten = 0
    pfx = ''
    if ( present(prefix) ) pfx = prefix
    open ( newunit = u, file = file, status = 'replace', action = 'write', iostat = ios )
    if ( ios /= 0 ) return
    do i = 1, g_count
      nm = trim ( g_names(i) )
      if ( env_keep ( nm, pfx ) ) then
        val = env_raw ( nm )
        write ( u, '(a)' ) nm//'='//val
        nwritten = nwritten + 1
      end if
    end do
    close ( u )
  end function

  ! sh-safe single-quoted literal: wrap in '...', turning each embedded ' into '\''.
  function env_sh_quote ( s ) result ( q )
    character(*), intent(in)  :: s
    character(:), allocatable :: q
    integer :: i
    q = "'"
    do i = 1, len ( s )
      if ( s(i:i) == "'" ) then
        q = q // "'\''"
      else
        q = q // s(i:i)
      end if
    end do
    q = q // "'"
  end function

  ! Like save, but write a RUNNABLE shell script of `export NAME='value'` lines
  ! (with a #!/bin/sh shebang and sh-safe quoting) and mark it executable.
  ! `source` it to set the variables in your current shell, or run it to seed a
  ! child process. Returns the number of variables written.
  function env_save_sh ( file, prefix ) result ( nwritten )
    character(*), intent(in)           :: file
    character(*), intent(in), optional :: prefix
    integer :: nwritten, u, i, ios, cst
    character(:), allocatable :: pfx, nm, val
    nwritten = 0
    pfx = ''
    if ( present(prefix) ) pfx = prefix
    open ( newunit = u, file = file, status = 'replace', action = 'write', iostat = ios )
    if ( ios /= 0 ) return
    write ( u, '(a)' ) '#!/bin/sh'
    write ( u, '(a)' ) '# generated by env_mo'
    do i = 1, g_count
      nm = trim ( g_names(i) )
      if ( env_keep ( nm, pfx ) ) then
        val = env_raw ( nm )
        write ( u, '(a)' ) 'export '//nm//'='//env_sh_quote ( val )
        nwritten = nwritten + 1
      end if
    end do
    close ( u )
    call execute_command_line ( "chmod +x '"//trim(file)//"'", wait = .true., cmdstat = cst )
  end function

  ! Companion to save_sh: write a runnable script of `unset NAME` lines (+x) that
  ! you `source` to CLEAR the tracked (or prefix-matching) vars from your shell —
  ! the undo for a save_sh. It does not touch this process's environment (call
  ! unset for that). Returns the number of variables written.
  function env_clear_sh ( file, prefix ) result ( nwritten )
    character(*), intent(in)           :: file
    character(*), intent(in), optional :: prefix
    integer :: nwritten, u, i, ios, cst
    character(:), allocatable :: pfx, nm
    nwritten = 0
    pfx = ''
    if ( present(prefix) ) pfx = prefix
    open ( newunit = u, file = file, status = 'replace', action = 'write', iostat = ios )
    if ( ios /= 0 ) return
    write ( u, '(a)' ) '#!/bin/sh'
    write ( u, '(a)' ) '# generated by env_mo'
    do i = 1, g_count
      nm = trim ( g_names(i) )
      if ( env_keep ( nm, pfx ) ) then
        write ( u, '(a)' ) 'unset '//nm
        nwritten = nwritten + 1
      end if
    end do
    close ( u )
    call execute_command_line ( "chmod +x '"//trim(file)//"'", wait = .true., cmdstat = cst )
  end function

end module
