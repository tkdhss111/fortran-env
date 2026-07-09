! Thin environment-variable reader for the tkd fleet. One-concept tool, same
! shape as cli_mo / logger_mo. Resolves data-path registry variables
! (/srv/data/tkd-config/data-paths.env, injected by a quadlet EnvironmentFile
! or `source`) with a compiled fallback, plus typed getters. Reads only — it
! never writes the environment, and needs no state.
!
! Usage:
!   use env_mo
!   type(env_ty) :: env
!   call env%override ( cf%dir_amedas, 'DIR_TKD_WX_JMA_AMEDAS_30MIN' )  ! keep default if unset
!   n   = env%get_integer ( 'FOR_COARRAY_NUM_IMAGES', 1 )
!   key = env%require     ( 'OPENMETEO_APIKEY' )                        ! error stop if unset

module env_mo

  implicit none

  private
  public :: env_ty

  integer, parameter :: MAXLEN = 4096   ! generous: long store paths, API keys

  type env_ty
  contains
    procedure, nopass :: override      => env_override
    procedure, nopass :: get_character => env_get_character
    procedure, nopass :: get_integer   => env_get_integer
    procedure, nopass :: get_real      => env_get_real
    procedure, nopass :: get_logical   => env_get_logical
    procedure, nopass :: is_set        => env_is_set
    procedure, nopass :: require       => env_require
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

  ! Overwrite `path` in place from $name when set & non-empty; otherwise leave
  ! the caller's compiled default untouched. The registry-override primitive.
  subroutine env_override ( path, name )
    character(*), intent(inout) :: path
    character(*), intent(in)    :: name
    character(MAXLEN) :: val
    integer :: ln, st
    call get_environment_variable ( name, val, length = ln, status = st )
    if ( st == 0 .and. ln > 0 ) path = trim(val)
  end subroutine

  ! $name as string, else `default` (or '' when no default is given).
  function env_get_character ( name, default ) result ( str )
    character(*), intent(in)           :: name
    character(*), intent(in), optional :: default
    character(:), allocatable :: str
    character(MAXLEN) :: val
    integer :: ln, st
    call get_environment_variable ( name, val, length = ln, status = st )
    if ( st == 0 .and. ln > 0 ) then
      str = trim(val)
    else if ( present(default) ) then
      str = default
    else
      str = ''
    end if
  end function

  ! $name parsed as integer, else `default` (also on a parse error).
  function env_get_integer ( name, default ) result ( ival )
    character(*), intent(in) :: name
    integer,      intent(in) :: default
    integer :: ival, ios
    character(:), allocatable :: s
    s = env_get_character ( name )
    ival = default
    if ( len_trim(s) > 0 ) then
      read ( s, *, iostat = ios ) ival
      if ( ios /= 0 ) ival = default
    end if
  end function

  ! $name parsed as real, else `default` (also on a parse error).
  function env_get_real ( name, default ) result ( rval )
    character(*), intent(in) :: name
    real,         intent(in) :: default
    real :: rval
    integer :: ios
    character(:), allocatable :: s
    s = env_get_character ( name )
    rval = default
    if ( len_trim(s) > 0 ) then
      read ( s, *, iostat = ios ) rval
      if ( ios /= 0 ) rval = default
    end if
  end function

  ! $name as logical (T/t/1/Y/y = true, F/f/0/N/n = false), else `default`.
  function env_get_logical ( name, default ) result ( ok )
    character(*), intent(in) :: name
    logical,      intent(in) :: default
    logical :: ok
    character(:), allocatable :: s
    ok = default
    s = env_get_character ( name )
    if ( len_trim(s) > 0 ) then
      select case ( s(1:1) )
      case ( 'T', 't', '1', 'Y', 'y' ) ; ok = .true.
      case ( 'F', 'f', '0', 'N', 'n' ) ; ok = .false.
      end select
    end if
  end function

  ! Required variable: return it, or print + error stop if unset (secrets / critical config).
  function env_require ( name ) result ( str )
    character(*), intent(in) :: name
    character(:), allocatable :: str
    if ( env_is_set ( name ) ) then
      str = env_get_character ( name )
    else
      write ( *, '(a)' ) 'env_mo: FATAL required environment variable not set: '//trim(name)
      error stop 1
    end if
  end function

end module
