let Action =
  < Shell : Text
  | Copy  : { from : Text, to : Text }
  | Mkdir : Text
  | Rm    : Text
  | Touch : Text
  >

let Target = { deps : List Text, phony : Bool, recipe : List Action }

in  { targets =
        [ { mapKey = "hello"
          , mapValue =
              { deps = [ "hello.c" ], phony = False
              , recipe = [ < Shell = "cc -o hello hello.c" > ]
              }
          }
        , { mapKey = "clean"
          , mapValue =
              { deps = [] : List Text, phony = True
              , recipe = [ < Rm = "hello" > ]
              }
          }
        ]
    , default = "hello"
    }
