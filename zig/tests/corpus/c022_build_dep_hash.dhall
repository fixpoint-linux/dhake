let Action = < Shell : Text | Copy : { from : Text, to : Text } >
let Target = { deps : List Text, phony : Bool, recipe : List Action, hash : Text, depsHash : List { path : Text, hash : Text } }
in  { targets = [ { mapKey = "depout28.txt", mapValue = { deps = ["input28.txt"], phony = False, recipe = [ < Copy = { from = "input28.txt", to = "depout28.txt" } > ], depsHash = [ { path = "input28.txt", hash = "sha256:${HASH28}" } ] } } ], default = "depout28.txt" }
