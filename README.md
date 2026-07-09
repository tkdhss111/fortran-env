# fortran-env

A simple environment-variable reader for Fortran — the shared registry-override tool for the tkd fleet.

Resolves data-path registry variables (`/srv/data/tkd-config/data-paths.env`, injected via a quadlet
`EnvironmentFile` or `source`) with a compiled fallback, plus typed getters. Reads only; no state.

## Use

Vendor `src/env_mo.f90` into your project's `app/` (like `cli_mo.f90`) and add it to `${SRCS}`.

```fortran
use env_mo
type(env_ty) :: env

! override a compiled default in place, only when the var is set (the registry no-op pattern)
call env%override ( cf%dir_amedas, 'DIR_TKD_WX_JMA_AMEDAS_30MIN' )

n   = env%get_integer   ( 'FOR_COARRAY_NUM_IMAGES', 1 )
x   = env%get_real      ( 'HALFLIFE_DAYS', 90.0 )
ok  = env%get_logical   ( 'IS_EVAL', .false. )
s   = env%get_character ( 'SOME_DIR', '/srv/data/default' )
key = env%require       ( 'OPENMETEO_APIKEY' )   ! error stop if unset (secrets / critical config)
```

## API (`env_ty`)

| method | behaviour |
|---|---|
| `override(path, name)` | overwrite `path` in place if `$name` set & non-empty; else leave the compiled default |
| `get_character(name[, default])` | `$name`, else `default` (else `''`) |
| `get_integer(name, default)` | parsed int, else `default` (also on parse error) |
| `get_real(name, default)` | parsed real, else `default` |
| `get_logical(name, default)` | `T/t/1/Y/y` → true, `F/f/0/N/n` → false, else `default` |
| `is_set(name)` | true if present & non-empty |
| `require(name)` | returns `$name`, or prints + `error stop` if unset |

## Test

```
make test
```
