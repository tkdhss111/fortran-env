# fortran-env

A small, self-contained environment-variable module for Fortran — one concept, one type (`env_ty`).

Reads variables into any scalar type through **one polymorphic getter** (`class(*)` + `select type`) — no
`get_integer` / `get_real` / `get_logical` clutter — with a compiled-in default. It also ingests namelist /
`.env` files into the environment and writes them back out.

Portable across **gfortran and ifx**: pure Fortran except a single libc `setenv`/`unsetenv` binding (the one
thing standard Fortran cannot do). No fragile `environ`/`__environ` symbol tricks.

## Use

Copy `src/env_mo.f90` into your project (or add it as a submodule) and compile it with your sources.

```fortran
use env_mo
type(env_ty)   :: env
integer        :: n   = 1
real           :: x   = 90.0
logical        :: ok  = .false.
character(255) :: dir = '/var/data/default'

! One getter for every scalar type — val is intent(inout), so it doubles as the default.
call env%get ( 'NUM_THREADS', n )                   ! n stays 1 if unset/unparseable
call env%get ( 'HALFLIFE_DAYS', x, 90.0 )           ! or pass the default explicitly
call env%get ( 'VERBOSE', ok )

! Override (get with args swapped): overwrite in place only when the var is set.
call env%override ( dir, 'DATA_DIR' )

key = env%require ( 'API_KEY' )                     ! error stop if unset (secrets / critical config)
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
| combination | applied left to right, no doubled `_` | `NML%N(1)%ITEM` → `NML_N_1_ITEM` |

So a namelist like

```fortran
&config
  NML%DIR%INPUT = "/var/data/input"
  NML%N(1)%ITEM = 24
  NML%FLAG      = T
/
```

becomes the environment variables `NML_DIR_INPUT=/var/data/input`, `NML_N_1_ITEM=24`, `NML_FLAG=T`.

```fortran
n = env%load_namelist ( 'config.nml' )                 ! returns the count set
call env%get ( 'NML_DIR_INPUT', dir )                  ! read it back (any type)

call env%set ( 'DATA_DIR', '/var/data' )               ! set one var
```

Values are de-quoted, a trailing comma or inline `! comment` is stripped, and `&group` / `/` / blank /
comment lines are skipped. Setting is done through libc `setenv` (via `iso_c_binding`) — visible to this
process and any children it spawns.

### `.env` round-trip and validation

`load` reads a plain `.env` (`KEY=VALUE` lines, `#`/`!` comments, optional `export `), and `save` writes
back out — but **only the variables env_mo itself has set/loaded**, never ambient ones. So a loaded config
round-trips, while secrets you only *read* (via `require`/`get`) are never dumped. `save` never enumerates
the raw process environment, which keeps it portable and leak-safe.

```fortran
n = env%load ( 'config.env' )                            ! .env  -> env vars ($VAR expanded)
n = env%save ( 'out.env', 'APP_' )                       ! tracked APP_* -> .env (systemd/container env-file)
n = env%save_sh  ( 'setenv.sh',   'APP_' )               ! ... or a runnable `export` script — `source` it
n = env%clear_sh ( 'clearenv.sh', 'APP_' )               ! ... and its undo: a runnable `unset` script
call env%unset ( 'TMP_VAR' )                             ! unsetenv + untrack
```

**Variable expansion.** `load` / `load_namelist` expand `$VAR` and `${VAR}` in values against the vars set
so far (line by line, like `source`), an unset reference becoming empty. So a config file with
`CACHE_DIR=$DATA_DIR/cache` resolves in-process, letting `env_mo` stand in for a shell that would otherwise
pre-expand the file. Use `expand` directly for one string.

**Three writers.** `save` emits plain `KEY=VALUE` (a systemd `EnvironmentFile`, a container `--env-file`);
`save_sh` emits a runnable `#!/bin/sh` script of `export NAME='value'` lines (sh-safe quoting, marked
executable) that you `source` to set the vars in your shell; `clear_sh` emits the matching `unset NAME`
script to clear them again.

Names are validated on the way in — `load`/`load_namelist` skip any key that isn't a POSIX identifier.
Check inputs yourself with `is_name` / `bad_char`:

```fortran
if ( .not. env%is_name ( key ) )   ...                   ! valid env-var name?
if ( env%bad_char ( value ) /= 0 ) ...                   ! position of first unpermitted char (0 = clean)
if ( env%bad_char ( code, '0123456789ABCDEF' ) /= 0 ) .. ! or against your own allowed set
```

## API (`env_ty`)

| method | behaviour |
|---|---|
| `get(name, val[, default])` | fetch `$name` into `val` (character/integer/real/double/logical); keep `default` or `val`'s incoming value if unset/unparseable |
| `override(val, name)` | overwrite `val` in place if `$name` set & non-empty; else keep the compiled default (get alias) |
| `is_set(name)` | true if present & non-empty |
| `is_name(name)` | true if `name` is a valid POSIX env-var identifier |
| `bad_char(str[, allowed])` | position of the first char not in `allowed` (default: the env-name charset); `0` = all permitted |
| `require(name)` | returns `$name` string, or prints + `error stop` if unset |
| `set(name, value)` | set/overwrite `$name` via `setenv` and track it for `save` (ignored if `name` invalid) |
| `unset(name)` | `unsetenv` and drop it from tracking |
| `expand(str)` | expand `$VAR` / `${VAR}` against the environment (unset → `''`); returns the string |
| `mangle_key(key)` | namelist key → env name (`%` and subscripts → `_`) |
| `load_namelist(file[, prefix])` | namelist file → env vars, each key `mangle_key`-ed, values `$VAR`-expanded; returns count |
| `load(file)` | plain `.env` file → env vars (keys verbatim, values `$VAR`-expanded); returns count |
| `save(file[, prefix])` | write tracked vars to a `.env` file (`KEY=VALUE`), optionally prefix-filtered; returns count |
| `save_sh(file[, prefix])` | write tracked vars to a runnable `export` shell script (`+x`); returns count |
| `clear_sh(file[, prefix])` | write a runnable `unset` shell script (`+x`) — the undo for `save_sh`; returns count |

## Test

`make test` builds the suite and runs it under `ctest`. 62 assertions cover every method — the polymorphic
getter across all scalar types, namelist mangling, `.env` load/save round-trips, `$VAR` expansion, name
validation, and the shell-script writers. All pass on **gfortran** and **ifx**.

```
make test
```

<details>
<summary><b>Test output</b> — 62/62 assertions pass</summary>

```
===== fortran-env unit test =====
PASS  get character keeps default when unset
PASS  get integer keeps default when unset
PASS  get real keeps default when unset
PASS  get double keeps default when unset
PASS  get logical keeps default when unset
PASS  is_set = F when unset
PASS  get integer uses explicit default when unset
PASS  override no-op when unset
PASS  get character when set
PASS  get integer when set
PASS  get real when set
PASS  get double when set
PASS  get logical when set (T)
PASS  is_set = T when set
PASS  override applies when set
PASS  get integer keeps default on parse error
PASS  require returns when set
PASS  mangle a%b%c
PASS  mangle %(n)%
PASS  mangle (i,j)
PASS  mangle trailing (i)
PASS  mangle no-op
PASS  set + get roundtrip
PASS  load_namelist sets 3 vars
PASS  namelist % path (comment/comma stripped)
PASS  namelist array-index integer
PASS  namelist logical
PASS  save writes exactly the 3 NML_ vars
PASS  save wrote the exact KEY=VALUE line
PASS  prefix filter keeps non-matching (secret) vars out
PASS  load sets 3 valid vars (comments/blank/bad-name skipped)
PASS  load plain KEY=VALUE
PASS  load strips `export ` and parses int
PASS  load de-quotes a "..." value
PASS  round trip: save wrote 2 RT_ vars
PASS  round trip: load read 2 RT_ vars back
PASS  save without prefix dumps all tracked vars
PASS  is_name accepts a valid name
PASS  is_name accepts leading underscore
PASS  is_name rejects a leading digit
PASS  is_name rejects a hyphen
PASS  is_name rejects empty
PASS  bad_char: clean name -> 0
PASS  bad_char: flags * at position 3
PASS  bad_char: custom allowed set, clean
PASS  bad_char: custom allowed set, z at 3
PASS  expand $VAR
PASS  expand ${VAR}
PASS  expand undefined $VAR -> empty
PASS  literal $ (not a ref) kept
PASS  load with expansion: 3 vars
PASS  load expands $VAR to a prior var
PASS  load expands undefined ${VAR} to empty
PASS  set before unset
PASS  unset removes the var
PASS  unset also untracks (save skips it)
PASS  save_sh writes 2 SH_ vars
PASS  save_sh wrote a plain export line
PASS  save_sh escaped an embedded single quote
PASS  clear_sh writes 2 unset lines
PASS  clear_sh wrote an unset line
=================================
ALL TESTS PASSED
```

</details>
