-- Dhakefile.dhall — self-hosting buildfile for dhake.
--
-- Builds `dhake.com` (the dhake binary) from src/dhake.c plus the dhall-c
-- interpreter core, using cosmocc.  Run with:
--
--     ./dhake.com.dbg          # build the default target (dhake.com)
--     ./dhake.com.dbg clean    # remove the built binary
--     ./dhake.com.dbg --list   # list targets
--
-- The `dhake.com` binary that results is itself a dhake executable: dhake
-- builds dhake.  The committed dhake.com is the bootstrap that builds the
-- first copy from source.

let Action =
      < Shell : Text
      | Copy : { from : Text, to : Text }
      | Mkdir : Text
      | Rm : Text
      | Touch : Text
      >

let Target = { deps : List Text, phony : Bool, recipe : List Action }

-- dhall-c interpreter core sources + headers (must match Makefile CORE_DHALL;
-- the .h files are included via -I so a header change must trigger a rebuild).
let core =
      [ "vendor/dhall-c/src/arena.c"
      , "vendor/dhall-c/src/lexer.c"
      , "vendor/dhall-c/src/parser.c"
      , "vendor/dhall-c/src/ast.c"
      , "vendor/dhall-c/src/normalize.c"
      , "vendor/dhall-c/src/typecheck.c"
      , "vendor/dhall-c/src/builtins.c"
      , "vendor/dhall-c/src/serialize.c"
      , "vendor/dhall-c/src/import.c"
      , "vendor/dhall-c/src/bignum.c"
      , "vendor/dhall-c/src/sha256.c"
      , "vendor/dhall-c/src/ssrf.c"
      , "vendor/dhall-c/src/http.c"
      , "vendor/dhall-c/src/dhall.h"
      , "vendor/dhall-c/src/ssrf.h"
      , "vendor/dhall-c/src/json.h"
      ]

in  { targets =
        [ { mapKey = "dhake.com"
          , mapValue =
              { deps = [ "src/dhake.c" ] # core
              , phony = False
              , recipe =
                  [ < Shell =
                        "cosmocc -std=c11 -O2 -g -Wall -Wextra "
                      ++ "-D_POSIX_C_SOURCE=200809L -I vendor/dhall-c/src "
                      ++ "-o dhake.com src/dhake.c vendor/dhall-c/src/arena.c "
                      ++ "vendor/dhall-c/src/lexer.c vendor/dhall-c/src/parser.c "
                      ++ "vendor/dhall-c/src/ast.c vendor/dhall-c/src/normalize.c "
                      ++ "vendor/dhall-c/src/typecheck.c vendor/dhall-c/src/builtins.c "
                      ++ "vendor/dhall-c/src/serialize.c vendor/dhall-c/src/import.c "
                      ++ "vendor/dhall-c/src/bignum.c vendor/dhall-c/src/sha256.c "
                      ++ "vendor/dhall-c/src/ssrf.c vendor/dhall-c/src/http.c"
                    >
                  ]
              }
          }
        , { mapKey = "clean"
          , mapValue = { deps = [] : List Text, phony = True, recipe = [ < Rm = "dhake.com" > ] }
          }
        ]
      , default = "dhake.com"
      }
