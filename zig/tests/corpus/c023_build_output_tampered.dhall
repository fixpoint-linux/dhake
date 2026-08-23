let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action, hash : Text, depsHash : List { path : Text, hash : Text } }
in  { targets = [ { mapKey = "out29.txt", mapValue = { deps = [], phony = False, recipe = [ < Shell = "printf 'hello29' > out29.txt" > ], hash = "sha256:${HASH29}" } } ], default = "out29.txt" }
