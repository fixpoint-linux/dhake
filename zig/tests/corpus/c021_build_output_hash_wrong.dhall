let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action, hash : Text, depsHash : List { path : Text, hash : Text } }
in  { targets = [ { mapKey = "out27.txt", mapValue = { deps = [], phony = False, recipe = [ < Shell = "printf 'hello' > out27.txt" > ], hash = "sha256:0000000000000000000000000000000000000000000000000000000000000000" } } ], default = "out27.txt" }
