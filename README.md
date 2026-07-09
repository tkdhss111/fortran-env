# fortran-env

The shared environment-variable tool for the tkd fleet — one concept, same shape as `fortran-CLI`.

Resolves data-path registry variables (`/srv/data/tkd-config/data-paths.env`, injected via a quadlet
`EnvironmentFile` or `source`) with a compiled fallback, through **one polymorphic getter** (`class(*)` +
`select type`) — no `get_integer` / `get_real` / `get_logical` clutter. It can also ingest a Fortran
namelist file, turning each `KEY = VALUE` into an environment variable.

## Use

Vendor `src/env_mo.f90` into your project's `app/` (like `cli_mo.f90`) and add it to `${SRCS}`.

```fortran
use env_mo
type(env_ty)   :: env
integer        :: n   = 1
real           :: x   = 90.0
logical        :: ok  = .false.
character(255) :: dir = '/srv/data/default'

! One getter for every scalar type — val is intent(inout), so it doubles as the default.
call env%get ( 'FOR_COARRAY_NUM_IMAGES', n )        ! n stays 1 if unset/unparseable
call env%get ( 'HALFLIFE_DAYS', x, 90.0 )           ! or pass the default explicitly
call env%get ( 'IS_EVAL', ok )

! Registry no-op override (get with args swapped): overwrite in place only when set.
call env%override ( dir, 'DIR_TKD_WX_JMA_AMEDAS' )

key = env%require ( 'OPENMETEO_APIKEY' )            ! error stop if unset (secrets / critical config)
```

### Namelist → environment variables

Ingest a Fortran namelist file; each `KEY = VALUE` becomes an env var. Environment-variable names cannot
contain `%` or `()`, so the namelist key is **mangled** into a valid name.

**Why:** a namelist key names a slot in a derived type — `%` descends into a component and `(i)` selects an
array element. To flatten that path into a single flat env-var name, every structural separator becomes `_`:

| in the namelist | rule | in the environment |
|---|---|---|
| `%` (component of a derived type) | → `_` | `a%b` → `a_b` |
| `(i)` (array subscript) | parens drop, index kept | `a(1)` → `a_1` |
| `(i,j)` (multi-dim subscript) | comma → `_` | `a(1,2)` → `a_1_2` |
| combination | applied left to right, no doubled `_` | `NML%N(1)%TGTS` → `NML_N_1_TGTS` |

So a namelist like

```fortran
&config
  NML%DIR%WTHR_OBS = "/srv/data/jma=amedas"
  NML%N(1)%TGTS    = 24
  NML%SHRINK%FLAG  = T
/
```

becomes the environment variables `NML_DIR_WTHR_OBS=/srv/data/jma=amedas`, `NML_N_1_TGTS=24`,
`NML_SHRINK_FLAG=T`.

```fortran
n = env%load_namelist ( 'config.nml' )                 ! returns the count set
call env%get ( 'NML_DIR_WTHR_OBS', dir )               ! read it back (any type)

call env%set ( 'DIR_TKD_WX_JMA_AMEDAS', '/srv/data/tkd-wx-jma-amedas' )  ! set one var
```

Values are de-quoted, a trailing comma or inline `! comment` is stripped, and `&group` / `/` / blank /
comment lines are skipped. Setting is done through libc `setenv` (via `iso_c_binding`) — visible to this
process and any children it spawns.

## API (`env_ty`)

| method | behaviour |
|---|---|
| `get(name, val[, default])` | fetch `$name` into `val` (character/integer/real/double/logical); keep `default` or `val`'s incoming value if unset/unparseable |
| `override(val, name)` | overwrite `val` in place if `$name` set & non-empty; else keep the compiled default (get alias) |
| `is_set(name)` | true if present & non-empty |
| `require(name)` | returns `$name` string, or prints + `error stop` if unset |
| `set(name, value)` | set (or overwrite) `$name` via `setenv` |
| `mangle_key(key)` | namelist key → env name (`%` and subscripts → `_`) |
| `load_namelist(file[, prefix])` | read a namelist file; set each `KEY = VALUE` as `mangle_key(KEY)`; returns count |

## Test

```
make test
```
