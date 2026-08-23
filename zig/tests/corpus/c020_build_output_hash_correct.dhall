let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action, hash : Text, depsHash : List { path : Text, hash : Text } }
in  { targets = [ { mapKey = "out26.txt", mapValue = { deps = [], phony = False, recipe = [ < Shell = "printf 'hello' > out26.txt" > ], hash = "sha256:${HASH26}" } } ], default = "out26.txt" }
