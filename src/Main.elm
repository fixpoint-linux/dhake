module Main exposing (main)

{-| The dhake documentation page as a plain `Browser.element` app.

This module renders the entire dhake docs page — top nav, hero, and the
`#build` / `#features` / `#example` / `#why` sections plus footer — using the
shared `Fixpoint.*` design package (`design/src` is a source-directory in this
application's `elm.json`).

The first child of the view is `Fixpoint.Style.stylesheet`, which emits the full
brand stylesheet as a single `<style>` node. Because the page is pre-rendered
under happy-dom by `scripts/ssg.mjs`, that `<style>` node is carried into the
static HTML — the styling ships with the page instead of living in a committed
stylesheet.

It is rendered at build time only: `scripts/ssg.mjs` loads the compiled bundle
under happy-dom and calls `Elm.Main.init({ node })` to pre-render the page to
static `dist/index.html`. There is no client-side interactivity (the model is
unit, the only message is `NoOp`), so no JS shell is shipped — GitHub Pages just
serves the static file.

The text/content is byte-faithful to the former committed `docs/index.html`
(now generated from this app).

-}

import Browser
import Fixpoint.Card
import Fixpoint.Code
import Fixpoint.Footer
import Fixpoint.Grid
import Fixpoint.Hero
import Fixpoint.Nav
import Fixpoint.Section
import Fixpoint.Style
import Html exposing (Html, a, b, div, em, p, span, text)
import Html.Attributes exposing (attribute, class, href)


main : Program () Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }



-- MODEL


type alias Model =
    ()


type Msg
    = NoOp


init : () -> ( Model, Cmd Msg )
init _ =
    ( (), Cmd.none )


update : Msg -> Model -> ( Model, Cmd Msg )
update _ model =
    ( model, Cmd.none )


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.none



-- VIEW


view : Model -> Html Msg
view _ =
    div []
        [ Fixpoint.Style.stylesheet
        , navView
        , headerView
        , buildSection
        , featuresSection
        , exampleSection
        , whySection
        , footerView
        ]



-- Top nav (brand + anchor links)


navView : Html Msg
navView =
    Fixpoint.Nav.view
        { brand =
            span []
                [ span [ class "fx" ] [ text "fx" ]
                , text "://dhake"
                ]
        , links =
            [ a [ class "home", href "https://fixpointlinux.org/", attribute "data-mfe-route" "/" ]
                [ text "fixpoint-linux" ]
            , Fixpoint.Nav.link "#build" "build"
            , Fixpoint.Nav.link "#features" "features"
            , Fixpoint.Nav.link "#example" "example"
            , Fixpoint.Nav.link "#why" "why"
            ]
        , extra = []
        }



-- Hero


headerView : Html Msg
headerView =
    Fixpoint.Hero.view
        { prompt =
            [ Fixpoint.Hero.hash
            , text " dhake "
            , Fixpoint.Hero.dollar
            , text " dhake -j 4"
            , Fixpoint.Hero.blink
            ]
        , title =
            [ text "A build tool whose buildfile "
            , Fixpoint.Hero.fx [ text "can’t lie" ]
            , text "."
            ]
        , tagline =
            [ b [] [ text "Dhall" ]
            , text " is total, terminating, and typechecked — so your build definition always means exactly what it says. Typed actions · incremental · parallel · "
            , b [] [ text "hash-verified" ]
            , text " · "
            , b [] [ text "sandboxed" ]
            , text " · "
            , b [] [ text "self-hosting" ]
            , text "."
            ]
        }



-- Section: #build


buildSection : Html Msg
buildSection =
    Fixpoint.Section.view
        { id = "build"
        , title = "Build (self-hosting)"
        , hint = "// dhake builds itself from a Dhakefile.dhall"
        , children =
            [ p []
                [ text "No build system required — dhake evaluates its own buildfile and builds "
                , Fixpoint.Code.inline "dhake.com"
                , text " from source. The committed "
                , Fixpoint.Code.inline "dhake.com"
                , text " is the bootstrap binary."
                ]
            , Fixpoint.Code.block
                [ Fixpoint.Code.k "$"
                , text " "
                , Fixpoint.Code.g "./dhake.com.dbg"
                , text "          "
                , Fixpoint.Code.c "# evaluates Dhakefile.dhall, builds dhake.com"
                , text "\n"
                , Fixpoint.Code.k "$"
                , text " "
                , Fixpoint.Code.g "./dhake.com.dbg"
                , text " --list   "
                , Fixpoint.Code.c "# list targets"
                , text "\n"
                , Fixpoint.Code.k "$"
                , text " "
                , Fixpoint.Code.g "./tests/build.sh"
                , text " ./dhake.com.dbg   "
                , Fixpoint.Code.c "# run the test suite"
                ]
            ]
        }



-- Section: #features (6 cards)


featuresSection : Html Msg
featuresSection =
    Fixpoint.Section.view
        { id = "features"
        , title = "Features"
        , hint = "// parallel · typed · incremental · verified · sandboxed · cached"
        , children =
            [ Fixpoint.Grid.grid
                [ Fixpoint.Card.view
                    { n = "01"
                    , title = "Parallel builds"
                    , body =
                        [ Fixpoint.Code.inline "-j N"
                        , text " runs up to N independent targets concurrently. On first failure it stops scheduling new targets but lets running ones finish (make-style)."
                        ]
                    }
                , Fixpoint.Card.view
                    { n = "02"
                    , title = "Typed actions"
                    , body =
                        [ text "Recipes are Dhall tagged-union values: "
                        , Fixpoint.Code.inline "Shell"
                        , text ", "
                        , Fixpoint.Code.inline "Copy"
                        , text ", "
                        , Fixpoint.Code.inline "Mkdir"
                        , text ", "
                        , Fixpoint.Code.inline "Rm"
                        , text ", "
                        , Fixpoint.Code.inline "Touch"
                        , text ", "
                        , Fixpoint.Code.inline "Move"
                        , text ", "
                        , Fixpoint.Code.inline "Symlink"
                        , text ", "
                        , Fixpoint.Code.inline "Chmod"
                        , text ", "
                        , Fixpoint.Code.inline "Echo"
                        , text ", "
                        , Fixpoint.Code.inline "Env"
                        , text ", "
                        , Fixpoint.Code.inline "Run"
                        , text "."
                        ]
                    }
                , Fixpoint.Card.view
                    { n = "03"
                    , title = "Dependency graph"
                    , body =
                        [ text "Topologically orders targets, detects cycles, and builds only the subgraph reachable from the requested target(s)."
                        ]
                    }
                , Fixpoint.Card.view
                    { n = "04"
                    , title = "Incremental"
                    , body =
                        [ text "Nanosecond-mtime up-to-date checks skip unchanged targets and their dependency closures."
                        ]
                    }
                , Fixpoint.Card.view
                    { n = "05"
                    , title = "Dry-run & phony"
                    , body =
                        [ Fixpoint.Code.inline "-n"
                        , text " prints the actions without running them; phony targets (e.g. "
                        , Fixpoint.Code.inline "clean"
                        , text ") are always rebuilt."
                        ]
                    }
                , Fixpoint.Card.view
                    { n = "06"
                    , title = "Self-hosting, verified"
                    , body =
                        [ text "A single "
                        , Fixpoint.Code.inline "cosmocc"
                        , text " APE that runs on Linux, macOS, Windows, and the BSDs — and builds itself, with every source and the produced binary pinned by hash."
                        ]
                    }
                , Fixpoint.Card.view
                    { n = "07"
                    , title = "Verified builds"
                    , body =
                        [ Fixpoint.Code.inline "hash"
                        , text " / "
                        , Fixpoint.Code.inline "depsHash"
                        , text " pin the expected sha256 of outputs and source deps, checked before and after every build. Mismatches fail hard — unless you pass "
                        , Fixpoint.Code.inline "--warn-hash-mismatch"
                        , text ", which prints the new hash so pins are trivial to update."
                        ]
                    }
                , Fixpoint.Card.view
                    { n = "08"
                    , title = "Sandboxing (Landlock + seccomp)"
                    , body =
                        [ text "Opt-in write-containment by default — recipes can only write under the build tree, "
                        , Fixpoint.Code.inline "/tmp"
                        , text ", and an explicit "
                        , Fixpoint.Code.inline "unveil"
                        , text " whitelist. Set "
                        , Fixpoint.Code.inline "readExec"
                        , text " to also restrict reads and execs to the toolchain. Set "
                        , Fixpoint.Code.inline "denyNetwork"
                        , text " to block network socket creation via seccomp. A rogue recipe can't touch the rest of your disk or phone home."
                        ]
                    }
                , Fixpoint.Card.view
                    { n = "09"
                    , title = "Recursive Mkdir / Rm"
                    , body =
                        [ Fixpoint.Code.inline "Mkdir"
                        , text " and "
                        , Fixpoint.Code.inline "Rm"
                        , text " support "
                        , Fixpoint.Code.inline "parents"
                        , text " / "
                        , Fixpoint.Code.inline "recursive"
                        , text " flags for "
                        , Fixpoint.Code.inline "mkdir -p"
                        , text " and "
                        , Fixpoint.Code.inline "rm -rf"
                        , text " behaviour, while legacy bare-path usage stays non-recursive."
                        ]
                    }
                , Fixpoint.Card.view
                    { n = "10"
                    , title = "Lockfile / SBOM"
                    , body =
                        [ Fixpoint.Code.inline "--lock[=FILE]"
                        , text " writes a machine-readable "
                        , Fixpoint.Code.inline "dhake.lock"
                        , text " after a successful build: every target's output and dep hashes plus its transitive dependency closure. A commit-and-diff supply-chain artifact for CI and provenance tools."
                        ]
                    }
                , Fixpoint.Card.view
                    { n = "11"
                    , title = "Verify / check"
                    , body =
                        [ Fixpoint.Code.inline "--verify"
                        , text " (alias "
                        , Fixpoint.Code.inline "--check"
                        , text ") pre-flights a build: it checks every pinned hash and up-to-dateness without running any recipe. A cheap CI gate."
                        ]
                    }
                , Fixpoint.Card.view
                    { n = "12"
                    , title = "Content-addressed"
                    , body =
                        [ Fixpoint.Code.inline "--hash-uptodate"
                        , text " decides up-to-dateness by content hash instead of mtime — a touched-but-unchanged file no longer triggers a rebuild."
                        ]
                    }
                , Fixpoint.Card.view
                    { n = "13"
                    , title = "Dev-loop watch"
                    , body =
                        [ Fixpoint.Code.inline "--watch"
                        , text " (alias "
                        , Fixpoint.Code.inline "-w"
                        , text ") uses inotify on your source-file dependencies and rebuilds on any change — edit-save-refresh becomes a single seamless loop."
                        ]
                    }
                , Fixpoint.Card.view
                    { n = "14"
                    , title = "Explain / why"
                    , body =
                        [ Fixpoint.Code.inline "--explain"
                        , text " (alias "
                        , Fixpoint.Code.inline "--why"
                        , text ") prints why each dirty target needs rebuilding — newer dep, hash mismatch, or missing output — without running anything."
                        ]
                    }
                , Fixpoint.Card.view
                    { n = "15"
                    , title = "Quiet / silent"
                    , body =
                        [ Fixpoint.Code.inline "--quiet"
                        , text " (alias "
                        , Fixpoint.Code.inline "-s"
                        , text ") suppresses per-recipe command echo; summaries and errors stay visible."
                        ]
                    }
                , Fixpoint.Card.view
                    { n = "16"
                    , title = "Build parameters"
                    , body =
                        [ Fixpoint.Code.inline "--define KEY=VALUE"
                        , text " (alias "
                        , Fixpoint.Code.inline "-D"
                        , text ") injects values into the buildfile's "
                        , Fixpoint.Code.inline "env:"
                        , text " imports — one Dhakefile does debug/release or -O0/-O3, CMake-style."
                        ]
                    }
                , Fixpoint.Card.view
                    { n = "17"
                    , title = "Dependency graph"
                    , body =
                        [ Fixpoint.Code.inline "--graph[=dot|mermaid]"
                        , text " dumps the full resolved graph (target→dep edges, phony styling, expected hashes) — perfect for inspecting the topology and for docs."
                        ]
                    }
                , Fixpoint.Card.view
                    { n = "18"
                    , title = "Per-target cwd"
                    , body =
                        [ text "An optional "
                        , Fixpoint.Code.inline "cwd"
                        , text " field runs a target's recipe in a subdirectory — no shell "
                        , Fixpoint.Code.inline "cd"
                        , text " boilerplate, and it composes with the sandbox."
                        ]
                    }
                , Fixpoint.Card.view
                    { n = "19"
                    , title = "Multi-arch builds"
                    , body =
                        [ Fixpoint.Code.inline "--arch=NAME"
                        , text " sets "
                        , Fixpoint.Code.inline "$DHAKE_ARCH"
                        , text " and lets targets carry an "
                        , Fixpoint.Code.inline "arch"
                        , text " filter — one Dhakefile cross-compiles x86_64 and aarch64 from a single run."
                        ]
                    }
                , Fixpoint.Card.view
                    { n = "20"
                    , title = "Build cache"
                    , body =
                        [ Fixpoint.Code.inline "--cache[=DIR]"
                        , text " adds a ccache-style cache keyed on the target name, arch, recipe, and content hashes of all inputs. Unchanged inputs restore the output and skip the recipe — pinned output hashes are still verified on restore."
                        ]
                    }
                ]
            ]
        }



-- Section: #example


exampleSection : Html Msg
exampleSection =
    Fixpoint.Section.view
        { id = "example"
        , title = "Example Dhakefile.dhall"
        , hint = "// targets = List { mapKey, mapValue } · default required"
        , children =
            [ Fixpoint.Code.block exampleCodeBlock
            , p []
                [ text "Add optional "
                , Fixpoint.Code.inline "hash"
                , text " and "
                , Fixpoint.Code.inline "depsHash"
                , text " fields to pin the expected sha256 of outputs and source deps, "
                , Fixpoint.Code.inline "cwd"
                , text " to run the recipe in a subdirectory, and "
                , Fixpoint.Code.inline "arch"
                , text " to limit a target to a specific architecture. A top-level "
                , Fixpoint.Code.inline "sandbox"
                , text " block runs every recipe in a Landlock write-containment sandbox — see the README."
                ]
            ]
        }


{-| The example `Dhakefile.dhall` pre block. Transcribed line-for-line (with the
exact leading whitespace) from the former committed `docs/index.html`, using the
`Fixpoint.Code.k` (accent-2 keywords), `g` (accent values) and plain `text`
nodes. A `<pre>` preserves whitespace, so the spacing here matters.
-}
exampleCodeBlock : List (Html Msg)
exampleCodeBlock =
    [ Fixpoint.Code.k "let"
    , text " Action = "
    , Fixpoint.Code.g "<"
    , text " Shell : Text"
    , text "\n"
    , text "             "
    , Fixpoint.Code.g "|"
    , text " Rm : Text "
    , Fixpoint.Code.g ">"
    , text "\n"
    , Fixpoint.Code.k "let"
    , text " Target = { deps : List Text, phony : Bool, recipe : List Action"
    , text "\n"
    , text "             , hash : Text"
    , text "\n"
    , text "             , depsHash : List { path : Text, hash : Text }"
    , text "\n"
    , text "             , cwd : Text"
    , text "\n"
    , text "             , arch : Optional Text"
    , text "             }"
    , text "\n"
    , Fixpoint.Code.k "in"
    , text "  { sandbox = { enable = "
    , Fixpoint.Code.g "True"
    , text ", readExec = "
    , Fixpoint.Code.g "True"
    , text ", denyNetwork = "
    , Fixpoint.Code.g "True"
    , text ", unveil = [ "
    , Fixpoint.Code.g "\"rwc:~/.cache\""
    , text ", "
    , Fixpoint.Code.g "\"rwc:~/.npm\""
    , text " ] }"
    , text "\n"
    , text "  , targets ="
    , text "\n"
    , text "      [ { mapKey = "
    , Fixpoint.Code.g "\"hello\""
    , text "\n"
    , text "        , mapValue = { deps = [ "
    , Fixpoint.Code.g "\"hello.c\""
    , text " ], phony = "
    , Fixpoint.Code.g "False"
    , text "\n"
    , text "                     , recipe = [ "
    , Fixpoint.Code.g "<"
    , text " Shell = "
    , Fixpoint.Code.g "\"cc -o hello hello.c\""
    , text " "
    , Fixpoint.Code.g ">"
    , text " ]"
    , text "\n"
    , text "                     , hash = "
    , Fixpoint.Code.g "\"sha256:abc123…\""
    , text "\n"
    , text "                     , depsHash = [ { path = "
    , Fixpoint.Code.g "\"hello.c\""
    , text ", hash = "
    , Fixpoint.Code.g "\"sha256:def456…\""
    , text " } ]"
    , text "\n"
    , text "                     , cwd = "
    , Fixpoint.Code.g "\"src\""
    , text "\n"
    , text "                     , arch = "
    , Fixpoint.Code.g "None Text"
    , text "\n"
    , text "                     }"
    , text "\n"
    , text "        }"
    , text "\n"
    , text "      , { mapKey = "
    , Fixpoint.Code.g "\"clean\""
    , text "\n"
    , text "        , mapValue = { deps = [] : List Text, phony = "
    , Fixpoint.Code.g "True"
    , text "\n"
    , text "                     , recipe = [ "
    , Fixpoint.Code.g "<"
    , text " Rm = "
    , Fixpoint.Code.g "\"hello\""
    , text " "
    , Fixpoint.Code.g ">"
    , text " ] }"
    , text "\n"
    , text "        }"
    , text "\n"
    , text "      ]"
    , text "\n"
    , text "  , default = "
    , Fixpoint.Code.g "\"hello\""
    , text "\n"
    , text "  }"
    ]



-- Section: #why


whySection : Html Msg
whySection =
    Fixpoint.Section.view
        { id = "why"
        , title = "Why Dhall?"
        , hint = "// total · terminating · typechecked"
        , children =
            [ p []
                [ text "Makefiles are turing-tarpit shell scripts with surprising whitespace semantics. Dhall is a strongly-typed, "
                , em [] [ text "total" ]
                , text " configuration language — your build definition gets type checking, imports, and reusable functions, and it always terminates. The build plan is a plain value you can reason about, not a recipe of shell side effects."
                ]
            ]
        }



-- Footer


footerView : Html Msg
footerView =
    Fixpoint.Footer.view
        [ a [ href "https://github.com/fixpoint-linux/dhake" ]
            [ text "github.com/fixpoint-linux/dhake" ]
        , Fixpoint.Footer.sep
        , text "part of "
        , a [ href "https://fixpointlinux.org" ] [ text "fixpoint-linux" ]
        , Fixpoint.Footer.sep
        , text "MIT"
        ]
