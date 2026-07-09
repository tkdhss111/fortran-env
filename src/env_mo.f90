! Thin environment-variable tool for the tkd fleet. One-concept tool, same shape
! as cli_mo / logger_mo. Resolves data-path registry variables
! (/srv/data/tkd-config/data-paths.env, injected by a quadlet EnvironmentFile or
! `source`) with a compiled fallback, via ONE polymorphic getter — no get_<type>.
! It can also INGEST a Fortran namelist file, setting each `KEY = VALUE` as an env
! var. Env names can't hold `%` or `()`, so the key is mangled to a flat name —
! every structural separator becomes `_`:
!     a%b     ->  a_b        ( `%` derived-type component  -> `_` )
!     a(1)    ->  a_1        ( `(i)` array subscript        -> `_i` )
!     a(1,2)  ->  a_1_2      ( `(i,j)` multi-dim subscript  -> `_i_j` )
!     NML%DIR%WTHR_OBS  ->  NML_DIR_WTHR_OBS
!     NML%N(1)%TGTS     ->  NML_N_1_TGTS
!
! Usage:
!   use env_mo
!   type(env_ty)   :: env
!   integer        :: n   = 1
!   real           :: x   = 90.0
!   logical        :: ok  = .false.
!   character(255) :: dir = '/srv/data/default'
!   call env%get ( 'FOR_COARRAY_NUM_IMAGES', n )         ! any scalar type; n kept if unset
!   call env%get ( 'HALFLIFE_DAYS', x, 90.0 )            ! explicit default also accepted
!   call env%override ( dir, 'DIR_TKD_WX_JMA_AMEDAS' )   ! registry no-op override (get alias)
!   n   = env%load_namelist ( 'config.nml' )             ! namelist file -> env vars
!   key = env%require ( 'OPENMETEO_APIKEY' )             ! required string, else error stop

module env_mo

  use, intrinsic :: iso_c_binding, only : c_char, c_int, c_null_char

  implicit none

  private
  public :: env_ty

  integer, parameter :: MAXLEN = 4096          ! generous: long store paths, API keys
  integer, parameter :: dp     = kind(1.0d0)   ! double-precision get() targets

  ! libc setenv — the only portable way to *set* an env var from Fortran.
  interface
    function c_setenv ( name, value, overwrite ) bind(C, name = 'setenv') result ( r )
      import :: c_char, c_int
      character(kind=c_char), intent(in) :: name(*), value(*)
      integer(c_int), value :: overwrite
      integer(c_int)        :: r
    end function
  end interface

  type env_ty
  contains
    procedure, nopass :: get           => env_get            ! polymorphic getter (any scalar type)
    procedure, nopass :: override      => env_override       ! in-place registry override (get alias)
    procedure, nopass :: is_set        => env_is_set
    procedure, nopass :: require       => env_require        ! required string, else error stop
    procedure, nopass :: set           => env_set            ! setenv one variable
    procedure, nopass :: mangle_key    => env_mangle_key     ! namelist key -> env name
    procedure, nopass :: load_namelist => env_load_namelist  ! namelist file -> env vars
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

  ! Set (or overwrite) $name in the current process (inherited by child processes).
  subroutine env_set ( name, value )
    character(*), intent(in) :: name, value
    integer(c_int) :: r
    r = c_setenv ( trim(name)//c_null_char, trim(value)//c_null_char, 1_c_int )
  end subroutine

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
  ! `! comment`, and skips &group / '/' / blank / comment lines. Optional `prefix`
  ! is prepended to every env name. Returns the number of variables set.
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
      name = env_mangle_key ( key )
      if ( present(prefix) ) name = prefix//name
      call env_set ( name, val )
      nset = nset + 1
    end do
    close ( u )
  end function

end module
