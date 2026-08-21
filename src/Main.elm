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
import Html.Attributes exposing (class, href)


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
            [ Fixpoint.Nav.homeLink "/fixpoint-linux" "fixpoint-linux"
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
        , hint = "// parallel · typed · incremental"
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
                    , title = "Self-hosting"
                    , body =
                        [ text "A single "
                        , Fixpoint.Code.inline "cosmocc"
                        , text " APE that runs on Linux, macOS, Windows, and the BSDs — and builds itself."
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
    , text " Shell : Text | Copy : { from : Text, to : Text }"
    , text "\n"
    , text "             "
    , Fixpoint.Code.g "|"
    , text " Mkdir : Text | Rm : Text | Touch : Text"
    , text "\n"
    , text "             "
    , Fixpoint.Code.g "|"
    , text " Move : { from : Text, to : Text }"
    , text "\n"
    , text "             "
    , Fixpoint.Code.g "|"
    , text " Symlink : { from : Text, to : Text }"
    , text "\n"
    , text "             "
    , Fixpoint.Code.g "|"
    , text " Chmod : { path : Text, mode : Text }"
    , text "\n"
    , text "             "
    , Fixpoint.Code.g "|"
    , text " Echo : Text"
    , text "\n"
    , text "             "
    , Fixpoint.Code.g "|"
    , text " Env : { key : Text, value : Text }"
    , text "\n"
    , text "             "
    , Fixpoint.Code.g "|"
    , text " Run : { argv : List Text } "
    , Fixpoint.Code.g ">"
    , text "\n"
    , Fixpoint.Code.k "let"
    , text " Target = { deps : List Text, phony : Bool, recipe : List Action }"
    , text "\n"
    , Fixpoint.Code.k "in"
    , text "  { targets ="
    , text "\n"
    , text "        [ { mapKey = "
    , Fixpoint.Code.g "\"hello\""
    , text "\n"
    , text "          , mapValue = { deps = [ "
    , Fixpoint.Code.g "\"hello.c\""
    , text " ], phony = "
    , Fixpoint.Code.g "False"
    , text "\n"
    , text "                       , recipe = [ "
    , Fixpoint.Code.g "<"
    , text " Shell = "
    , Fixpoint.Code.g "\"cc -o hello hello.c\""
    , text " "
    , Fixpoint.Code.g ">"
    , text " ] } }"
    , text "\n"
    , text "        , { mapKey = "
    , Fixpoint.Code.g "\"clean\""
    , text "\n"
    , text "          , mapValue = { deps = [] : List Text, phony = "
    , Fixpoint.Code.g "True"
    , text "\n"
    , text "                       , recipe = [ "
    , Fixpoint.Code.g "<"
    , text " Rm = "
    , Fixpoint.Code.g "\"hello\""
    , text " "
    , Fixpoint.Code.g ">"
    , text " ] } }"
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
