let Action =
  < Shell : Text
  | Copy  : { from : Text, to : Text }
  | Mkdir : Text
  | Rm    : Text
  | Touch : Text
  >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in  { targets =
        [ { mapKey = "output.txt"
          , mapValue =
              { deps = [ "input.txt" ], phony = False
              , recipe = [ < Shell = "cat input.txt > output.txt && echo ran >> runs.log && echo modified" > ]
              }
          }
        ]
    , default = "output.txt"
    }
