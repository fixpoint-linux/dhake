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
-- ─── optional landlock sandbox + seccomp network deny ────────────────────
-- Add a top-level `sandbox = { enable, readExec, denyNetwork, unveil }` field to run
-- each recipe in a Landlock sandbox (see README "Sandboxing (Landlock)"):
--
--     , sandbox = { enable = True
--                 , readExec = True    -- optional: also restrict READ/EXECUTE
--                 , denyNetwork = True -- optional: deny network socket creation
--                 , unveil = [ "rwc:~/.npm", "rwc:~/.cache", "rwc:~/.elm" ]
--                 }
--
-- unveil entries are "perms:path" (default rwc). When readExec=False (default),
-- w/c are enforced (write/create/remove) and r/x are parsed but inert. When
-- readExec=True, r/x are also enforced (READ_FILE|READ_DIR and EXECUTE), and
-- standard toolchain dirs are auto-unveiled. When denyNetwork=True, a seccomp
-- BPF filter denies socket() for AF_INET/AF_INET6/AF_PACKET/AF_NETLINK (EPERM),
-- allowing only AF_UNIX/AF_LOCAL. A leading ~ expands to $HOME.
-- If landlock is unavailable (older kernel / non-Linux), dhake warns once and
-- runs unsandboxed, so builds keep working everywhere. If seccomp is unavailable
-- and denyNetwork=True, the recipe child fails closed (exit 3).
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

let Target = { deps : List Text, phony : Bool, recipe : List Action
             , hash : Optional Text
             , depsHash : Optional (List { path : Text, hash : Text })
             , arch : Optional Text
             }

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

-- hash of each `core` source, in the same order (verified-build integrity).
let coreHashes =
      [ { path = "vendor/dhall-c/src/arena.c"
        , hash = "sha256:d025633194ecae134ce25f47ed30d025cda3633ef7df749be8f812cac85a4b5e"
        }
      , { path = "vendor/dhall-c/src/lexer.c"
        , hash = "sha256:2eecc4703e64d2ee186ed3b65b87f973bbc3e5dc79bfc36096bd914bf33794ce"
        }
      , { path = "vendor/dhall-c/src/parser.c"
        , hash = "sha256:4c3bc73611a94df1dc9b15b28afa82403d18f9d876d29fcdb383fa6949b9c9f2"
        }
      , { path = "vendor/dhall-c/src/ast.c"
        , hash = "sha256:e7a4d62f2f26d612cbad6ca2d803c4b26d5ce35b12fe5ecb6033750833bd92d9"
        }
      , { path = "vendor/dhall-c/src/normalize.c"
        , hash = "sha256:323604b338f6e9f12a8a7552df38efd80574bfa8de15590d036efff699718ea2"
        }
      , { path = "vendor/dhall-c/src/typecheck.c"
        , hash = "sha256:f54567788bdd8ac65139926e3cef5e287e3882f02a35d95d2c4f2cac89d37c30"
        }
      , { path = "vendor/dhall-c/src/builtins.c"
        , hash = "sha256:bd8a279c18368f67fae78753dc7f7d0d8edba4651acaa34b960fcf05b42fc936"
        }
      , { path = "vendor/dhall-c/src/serialize.c"
        , hash = "sha256:1d47a1d828072c6c9284afe28410fa2ddde5dc18984583be620df8dcf27f20a9"
        }
      , { path = "vendor/dhall-c/src/import.c"
        , hash = "sha256:48d5014f36bac6bcbe836e612635b1954a963a7316658588c1eb4ed738b6858e"
        }
      , { path = "vendor/dhall-c/src/bignum.c"
        , hash = "sha256:01b43c3c980f88b80da7f26836458540c7fa611df5b5dc205f670aa5dc5188fd"
        }
      , { path = "vendor/dhall-c/src/sha256.c"
        , hash = "sha256:dfdd76023d85b821e735ecad9b0be3ef11129656feb018874461a00329ab279e"
        }
      , { path = "vendor/dhall-c/src/ssrf.c"
        , hash = "sha256:807c8acf89548b023df3393cc5f43ab31b0024c3b52c8482355b6162cff1cf81"
        }
      , { path = "vendor/dhall-c/src/http.c"
        , hash = "sha256:9dbbd36a61b2980bea214bb49eb64d19dae1ce6654685e3f77afccd3cbc453e3"
        }
      , { path = "vendor/dhall-c/src/dhall.h"
        , hash = "sha256:b1874785500777aa182e6bba791942660df8190253555a8017bc90d23a2107dc"
        }
      , { path = "vendor/dhall-c/src/ssrf.h"
        , hash = "sha256:5987d7ea8ce6ac1d6dfdcec1e199cd44ccb3235d537cd5724528867038451a3f"
        }
      , { path = "vendor/dhall-c/src/json.h"
        , hash = "sha256:0697fb1bde0c17749de18a9d59644a4c7adf438de96ed4733885e9bf2701ca4e"
        }
      ]

-- One Dhakefile cross-compiles N targets: `cTarget` builds the C binary for a
-- given architecture. Select which to build with --arch=NAME (default:
-- auto-detected native). E.g.:
--
--     ./dhake.com.dbg                       # build dhake.com (native x86_64)
--     ./dhake.com.dbg --arch=aarch64        # build dhake.com (fat APE)  [*]
--     ./dhake.com.dbg --arch=aarch64 dhake.aarch64.elf   # aarch64 ELF
--
-- [*] dhake.com is a fat APE and contains all archs; its `arch` field only
-- gates which recipe the default resolves to. dhake.aarch64.elf is the
-- single-arch aarch64 ELF produced by aarch64-unknown-cosmo-cc.
let cTarget = \(arch : Text) ->
      let cc  = if arch == "aarch64" then "aarch64-unknown-cosmo-cc" else "cosmocc"
      let out = if arch == "aarch64" then "dhake.aarch64.elf" else "dhake.com"
      let outHash =
            if arch == "aarch64"
            then "sha256:0171c80c632e18f7d5848c141ba9f961cc272d422f77cb7a7a491b3f523ea204"
            else "sha256:f41e5a0b9319c9245d16653a7359408ac05bc1761e256251c7c080e8ed34a8fe"
      in  { mapKey = out
          , mapValue =
              { deps = [ "src/dhake.c" ] # core
              , phony = False
              , arch = Some arch
              -- expected hash of the produced binary (verified after build)
              , hash = outHash
              -- expected hash of each source dep (verified before build)
              , depsHash =
                  [ { path = "src/dhake.c"
                    , hash = "sha256:0841363c882a87434b6f8ee754e1110f4156bbecbf17fcfd3a6cda3e70dcbdbe"
                    }
                  ] # coreHashes
              , recipe =
                  [ < Shell =
                        cc ++ " -std=c11 -O2 -g -Wall -Wextra "
                      ++ "-D_POSIX_C_SOURCE=200809L -I vendor/dhall-c/src "
                      ++ "-o " ++ out ++ " src/dhake.c vendor/dhall-c/src/arena.c "
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

-- dhall-c's parser does not allow function application directly inside a list
-- literal, so bind each per-arch target to a let first.
let x86 = cTarget "x86_64"
let arm = cTarget "aarch64"

in  { targets =
        [ x86
        , arm
        , { mapKey = "clean"
          , mapValue = { deps = [] : List Text, phony = True, recipe = [ < Rm = "dhake.com" > ], arch = None Text }
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
              -- expected hash of the produced dist/elm.js (verified after build).
              -- elm 0.19.2 --optimize output is byte-deterministic for identical
              -- inputs, so this pins the artifact. The `design/src` dep is a
              -- directory and cannot be file-hashed, so it is pinned transitively
              -- via this output hash (any change to it changes the elm.js bytes).
              , hash = "sha256:20f211115add12d8724552ae1763c5a96944af3d5affa997c0e08064d99020d5"
              , depsHash =
                  [ { path = "src/Main.elm"
                    , hash = "sha256:bda80ac47cb161b1824dbc06b560e5bbf2c32a894faa5e10eaf378123470d9ea"
                    }
                  , { path = "elm.json"
                    , hash = "sha256:e7fe37330383367eb15ef45d0461c840f74b2b6a9764dbf66dea2e59ba0edd99"
                    }
                  ]
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
              -- expected hash of the produced dist/index.html (verified after
              -- build). The ssg output is byte-deterministic for identical inputs.
              -- `dist/elm.js` (a target) and `vendor-mfe` (phony, multi-file) are
              -- verified transitively via this output hash.
              , hash = "sha256:3c8d769f76cd7c1c1694c2a0279eccc940d69ab5f3a9a13a7376e5fd25a55d8c"
              , depsHash =
                  [ { path = "shell/index.html"
                    , hash = "sha256:30b7a3675ed9af3ba31869b16ef4bcc933e09184799e69cea3897bb80d068fb0"
                    }
                  , { path = "scripts/ssg.mjs"
                    , hash = "sha256:ab39937ddb13b3b639fc7fd6bc4c5eeaae04ca1e1c63b53f712015a5c257adf1"
                    }
                  ]
              , recipe = [ < Shell = "node scripts/ssg.mjs" > ]
              }
          }

        -- ─── Zig self-host targets ─────────────────────────────────────────
        -- libdhall.so: the dhall-c interpreter core compiled by Zig as a shared
        -- library, consumed by the Zig dhake through the C-ABI seam
        -- (zig/src/dhall_abi.zig). The recipe uses `zig build-obj` + `cc -shared`
        -- + `strip` (NOT `zig build-lib`): build-lib output is non-deterministic
        -- (pointer-keyed anon symbols in .symtab) and would emit SONAME libabi.so,
        -- so its hash could never be pinned. This deterministic chain emits a
        -- standard ELF with the correct SONAME and byte-identical output, so the
        -- output hash is pinned. The ZIG_*_CACHE_DIR vars are set inline because
        -- dhake's recipe env does not inherit the build host's cache dirs.
        , { mapKey = "vendor/dhall-c/zig/lib/libdhall.so"
          , mapValue =
              { deps =
                  [ "vendor/dhall-c/zig/src/abi.zig"
                  , "vendor/dhall-c/zig/src/dhall.zig"
                  , "vendor/dhall-c/zig/src/arena.zig"
                  , "vendor/dhall-c/zig/src/ast.zig"
                  , "vendor/dhall-c/zig/src/parser.zig"
                  , "vendor/dhall-c/zig/src/normalize.zig"
                  , "vendor/dhall-c/zig/src/import.zig"
                  , "vendor/dhall-c/zig/src/sha256.zig"
                  , "vendor/dhall-c/zig/src/bignum.zig"
                  , "vendor/dhall-c/zig/src/lexer.zig"
                  , "vendor/dhall-c/zig/src/builtins.zig"
                  , "vendor/dhall-c/zig/src/http.zig"
                  , "vendor/dhall-c/zig/src/ssrf.zig"
                  ]
              , phony = False
              -- expected hash of the produced libdhall.so (verified after build)
              , hash = "sha256:0f40fc2e36afd42f25d7f0e792a160f47117191e7e40e9295401a65ac014bc2d"
              , depsHash =
                  [ { path = "vendor/dhall-c/zig/src/abi.zig"
                    , hash = "sha256:b469394990918f57b4dd7b06e1d18fa6f4c8e0c97b1bbd7e4dd3fb7ceacf105f"
                    }
                  , { path = "vendor/dhall-c/zig/src/dhall.zig"
                    , hash = "sha256:4dea854433832ad1080e0495268947acb22167048d7ddf8cea0ac1e61e900e29"
                    }
                  , { path = "vendor/dhall-c/zig/src/arena.zig"
                    , hash = "sha256:e34f53d9663581fa5be2138b2a71584dfcf4f17a76cccf6d77db0b7910a955eb"
                    }
                  , { path = "vendor/dhall-c/zig/src/ast.zig"
                    , hash = "sha256:b414df16e39a81e409cabf5843c12c9ed56eb4ecda70167955c177f06d7d6574"
                    }
                  , { path = "vendor/dhall-c/zig/src/parser.zig"
                    , hash = "sha256:e1f988face58db0961ab058bb4619d22a8c2fe567f666240ab719b85d10fd906"
                    }
                  , { path = "vendor/dhall-c/zig/src/normalize.zig"
                    , hash = "sha256:463d49ef6d3dbe9dde5700625616baf31bde9fa57950928f7a4f37c502de3d99"
                    }
                  , { path = "vendor/dhall-c/zig/src/import.zig"
                    , hash = "sha256:851f53d9409bf6ab950d614015b825e843406a1de89d80b8f9f1167d04afd1b3"
                    }
                  , { path = "vendor/dhall-c/zig/src/sha256.zig"
                    , hash = "sha256:f8606ab9bdb60f9cbf6f1f4763d140b79aa2afa352caf3d4409e9bdc11dba15b"
                    }
                  , { path = "vendor/dhall-c/zig/src/bignum.zig"
                    , hash = "sha256:5890fa076125f4dd9a642fa99c694653c0fde51215bb21f4d7bcebe610f6ae86"
                    }
                  , { path = "vendor/dhall-c/zig/src/lexer.zig"
                    , hash = "sha256:6d87085f98f36cbb1e91ad408ce8865bc27f78d8ea23a637817bafefa196b3fd"
                    }
                  , { path = "vendor/dhall-c/zig/src/builtins.zig"
                    , hash = "sha256:b99627cfa9a273ec1deedb1c19bde54d403182592ac90a9597d6deff19a554d7"
                    }
                  , { path = "vendor/dhall-c/zig/src/http.zig"
                    , hash = "sha256:6a2df3d94ccc723888a2ef5efe3b8d6fe6b620087e3de52bdddb93e8dcad71fb"
                    }
                  , { path = "vendor/dhall-c/zig/src/ssrf.zig"
                    , hash = "sha256:a8dbc2c3427d12b4a2860fa36afb145a468ac15ea66b447cfb4d9741a166e4d6"
                    }
                  ]
              , recipe =
                  [ < Shell =
                        "cd vendor/dhall-c/zig/src && rm -f ../lib/libdhall.so && "
                     ++ "ZIG_GLOBAL_CACHE_DIR=/tmp/.zcache ZIG_LOCAL_CACHE_DIR=/tmp/.zlcache "
                     ++ "zig build-obj abi.zig -lc -dynamic -O ReleaseSafe -fno-stack-check "
                     ++ "-femit-bin=/tmp/dhake-libdhall.o && "
                     ++ "cc -shared -o ../lib/libdhall.so /tmp/dhake-libdhall.o -lc "
                     ++ "-Wl,-soname,libdhall.so -Wl,--build-id=none && "
                     ++ "strip --strip-all ../lib/libdhall.so"
                    >
                  ]
              }
          }
        , { mapKey = "zig-out/dhake"
          , mapValue =
              { deps =
                  [ "zig/src/dhall_abi.zig"
                  , "zig/src/dhall_types.zig"
                  , "zig/src/eval.zig"
                  , "zig/src/exec.zig"
                  , "zig/src/graph.zig"
                  , "zig/src/hash.zig"
                  , "zig/src/main.zig"
                  , "zig/src/opts.zig"
                  , "zig/src/plan.zig"
                  , "zig/src/report.zig"
                  , "zig/src/sandbox.zig"
                  , "zig/src/sysio.zig"
                  , "zig/src/watch.zig"
                  , "zig/build.sh"
                    -- libdhall.so is a target dep, verified via its own output hash
                  , "vendor/dhall-c/zig/lib/libdhall.so"
                  ]
              , phony = False
              -- expected hash of the produced zig-out/dhake (verified after build)
              , hash = "sha256:ba8257a47e9a238a0fa9503362e5fee9a4f1879b4e9423a8d9132e8cf31e43f7"
              , depsHash =
                  [ { path = "zig/src/dhall_abi.zig"
                    , hash = "sha256:8d1e70b2c6896bcaa36da83f0e22bc50e3b0eb511d6064dba7e3af6e9b4880ef"
                    }
                  , { path = "zig/src/dhall_types.zig"
                    , hash = "sha256:4dea854433832ad1080e0495268947acb22167048d7ddf8cea0ac1e61e900e29"
                    }
                  , { path = "zig/src/eval.zig"
                    , hash = "sha256:e9304e6e33f632d9d3c453cbf4993270b69c4c7e779ea5d0a9b80fd1d4d14212"
                    }
                  , { path = "zig/src/exec.zig"
                    , hash = "sha256:8a38a546ef88ed44b399810b6bffd95e4d223b8c753d4430a7b1d49424568a19"
                    }
                  , { path = "zig/src/graph.zig"
                    , hash = "sha256:482e289d6252ffb7c2f3a7b0e593499199ff78f7cdbc8544c9ef3bbf6263a3a7"
                    }
                  , { path = "zig/src/hash.zig"
                    , hash = "sha256:9d6c126b3aa3cfbfd099f86a14446810275ec302f94f8ad4a25d0107853baa01"
                    }
                  , { path = "zig/src/main.zig"
                    , hash = "sha256:6420c3641eb5a5a815652948f8ef635c29f8897fe712223a8884d2fbab299108"
                    }
                  , { path = "zig/src/opts.zig"
                    , hash = "sha256:e4488d5fb5bfc9f181d9ee2794755a3d4ba5c9934d2ed812a837da938dca2a7f"
                    }
                  , { path = "zig/src/plan.zig"
                    , hash = "sha256:4c534811958d65be5f6f7c5320d8e863560d0b4eb1a28f459f99520926059946"
                    }
                  , { path = "zig/src/report.zig"
                    , hash = "sha256:8364790f050d9572015623cc506491a9a0b931752b3f9efb7d42bdabfa3b70ac"
                    }
                  , { path = "zig/src/sandbox.zig"
                    , hash = "sha256:ec7a949c73708c2c66482766d743792c8ebc892612cfa3be7b58944127948333"
                    }
                  , { path = "zig/src/sysio.zig"
                    , hash = "sha256:5c8eeb272f13c5e13d09d6c043ea73f803805dc292a04229cd2514be151a9a24"
                    }
                  , { path = "zig/src/watch.zig"
                    , hash = "sha256:7dc97167346ee1ad0dc58ebd78668a239618061d051b2714d1ed620f237188ab"
                    }
                  , { path = "zig/build.sh"
                    , hash = "sha256:72000f1ad1b7b8d26ad68ced228fcf4108b038fdf149db7be09073120b5fd634"
                    }
                  ]
              , recipe = [ < Shell = "bash zig/build.sh" > ]
              }
          }
        ]
      , default = "dhake.com"
      }
