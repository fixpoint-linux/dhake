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
--
-- ─── optional landlock sandbox ────────────────────────────────────────────
-- Add a top-level `sandbox = { enable, unveil }` field to run each recipe in
-- a write-containment Landlock sandbox (see README "Sandboxing (Landlock)"):
--
--     , sandbox = { enable = True
--                 , unveil = [ "rwc:~/.npm", "rwc:~/.cache", "rwc:~/.elm" ]
--                 }
--
-- unveil entries are "perms:path" (default rwc); w/c are enforced in v1,
-- r/x are parsed but inert. A leading ~ expands to $HOME. If landlock is
-- unavailable (older kernel / non-Linux), dhake warns once and runs
-- unsandboxed, so builds keep working everywhere.
-- ──────────────────────────────────────────────────────────────────────────

let Action =
      < Shell : Text
      | Copy : { from : Text, to : Text }
      | Mkdir : < Plain : Text | Parents : { path : Text, parents : Bool } >
      | Rm : < Plain : Text | Recursive : { path : Text, recursive : Bool } >
      | Touch : Text
      | Move : { from : Text, to : Text }
      | Symlink : { from : Text, to : Text }
      | Chmod : { path : Text, mode : Text }
      | Echo : Text
      | Env : { key : Text, value : Text }
      | Run : { argv : List Text }
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

        -- ─── docs site ───────────────────────────────────────────────────────
        -- The docs site (dhake.fixpointlinux.org) is an Elm app (src/Main.elm)
        -- rendered against the shared Fixpoint.* design package (the `design`
        -- submodule) plus the mfe-framework. This mirrors the main site's
        -- Dhakefile pipeline; the only difference is the ssg emits dist/index.html.
        --
        --   mfe-framework -> vendor-mfe -> dist/elm.js -> dist/index.html
        --
        , { mapKey = "mfe-framework"
          , mapValue =
              { deps = []
              , phony = True
              , recipe = [ < Shell = "cd mfe-framework && npm ci && npm run build" > ]
              }
          }
        , { mapKey = "vendor-mfe"
          , mapValue =
              { deps = [ "mfe-framework" ]
              , phony = True
              , recipe =
                  [ < Rm = < Recursive = { path = "vendor/@mfe", recursive = True } > >
                  , < Mkdir = < Parents = { path = "vendor/@mfe/core", parents = True } > >
                  , < Mkdir = < Parents = { path = "vendor/@mfe/framework", parents = True } > >
                  , < Shell =
                        "cp mfe-framework/packages/core/dist/*.js vendor/@mfe/core/"
                    >
                  , < Shell =
                        "cp mfe-framework/packages/framework/dist/*.js vendor/@mfe/framework/"
                    >
                  ]
              }
          }
        , { mapKey = "dist/elm.js"
          , mapValue =
              { deps = [ "src/Main.elm", "elm.json", "design/src" ]
              , phony = False
              , recipe =
                  [ < Shell =
                        "node_modules/elm/bin/elm make src/Main.elm --output=dist/elm.js --optimize"
                    >
                  ]
              }
          }
        , { mapKey = "dist/index.html"
          , mapValue =
              { deps =
                  [ "dist/elm.js"
                  , "vendor-mfe"
                  , "shell/index.html"
                  , "scripts/ssg.mjs"
                  ]
              , phony = False
              , recipe = [ < Shell = "node scripts/ssg.mjs" > ]
              }
          }
        ]
      , default = "dhake.com"
      }
