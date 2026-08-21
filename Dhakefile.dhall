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

-- sha256 of each `core` source, in the same order (verified-build integrity).
let coreHashes =
      [ { path = "vendor/dhall-c/src/arena.c"
        , sha256 = "d025633194ecae134ce25f47ed30d025cda3633ef7df749be8f812cac85a4b5e"
        }
      , { path = "vendor/dhall-c/src/lexer.c"
        , sha256 = "2eecc4703e64d2ee186ed3b65b87f973bbc3e5dc79bfc36096bd914bf33794ce"
        }
      , { path = "vendor/dhall-c/src/parser.c"
        , sha256 = "4c3bc73611a94df1dc9b15b28afa82403d18f9d876d29fcdb383fa6949b9c9f2"
        }
      , { path = "vendor/dhall-c/src/ast.c"
        , sha256 = "e7a4d62f2f26d612cbad6ca2d803c4b26d5ce35b12fe5ecb6033750833bd92d9"
        }
      , { path = "vendor/dhall-c/src/normalize.c"
        , sha256 = "323604b338f6e9f12a8a7552df38efd80574bfa8de15590d036efff699718ea2"
        }
      , { path = "vendor/dhall-c/src/typecheck.c"
        , sha256 = "f54567788bdd8ac65139926e3cef5e287e3882f02a35d95d2c4f2cac89d37c30"
        }
      , { path = "vendor/dhall-c/src/builtins.c"
        , sha256 = "bd8a279c18368f67fae78753dc7f7d0d8edba4651acaa34b960fcf05b42fc936"
        }
      , { path = "vendor/dhall-c/src/serialize.c"
        , sha256 = "1d47a1d828072c6c9284afe28410fa2ddde5dc18984583be620df8dcf27f20a9"
        }
      , { path = "vendor/dhall-c/src/import.c"
        , sha256 = "48d5014f36bac6bcbe836e612635b1954a963a7316658588c1eb4ed738b6858e"
        }
      , { path = "vendor/dhall-c/src/bignum.c"
        , sha256 = "01b43c3c980f88b80da7f26836458540c7fa611df5b5dc205f670aa5dc5188fd"
        }
      , { path = "vendor/dhall-c/src/sha256.c"
        , sha256 = "dfdd76023d85b821e735ecad9b0be3ef11129656feb018874461a00329ab279e"
        }
      , { path = "vendor/dhall-c/src/ssrf.c"
        , sha256 = "807c8acf89548b023df3393cc5f43ab31b0024c3b52c8482355b6162cff1cf81"
        }
      , { path = "vendor/dhall-c/src/http.c"
        , sha256 = "9dbbd36a61b2980bea214bb49eb64d19dae1ce6654685e3f77afccd3cbc453e3"
        }
      , { path = "vendor/dhall-c/src/dhall.h"
        , sha256 = "b1874785500777aa182e6bba791942660df8190253555a8017bc90d23a2107dc"
        }
      , { path = "vendor/dhall-c/src/ssrf.h"
        , sha256 = "5987d7ea8ce6ac1d6dfdcec1e199cd44ccb3235d537cd5724528867038451a3f"
        }
      , { path = "vendor/dhall-c/src/json.h"
        , sha256 = "0697fb1bde0c17749de18a9d59644a4c7adf438de96ed4733885e9bf2701ca4e"
        }
      ]

in  { targets =
        [ { mapKey = "dhake.com"
          , mapValue =
              { deps = [ "src/dhake.c" ] # core
              , phony = False
              -- expected sha256 of the produced dhake.com (verified after build)
              , sha256 = "b5865087925205249ffdccc083fc9c346b287cd6a2d3f36e5f9f6b3c79d8ff22"
              -- expected sha256 of each source dep (verified before build)
              , depsSha256 =
                  [ { path = "src/dhake.c"
                    , sha256 = "807ae462ae79ef6d0057f00828b9088b4bddd6a26f7a90533139116337a3168f"
                    }
                  ] # coreHashes
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
