let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action, hash : Text, depsHash : List { path : Text, hash : Text } }
in  { targets = [ { mapKey = "out33.txt", mapValue = { deps = [ "warn33_input.txt" ], phony = False, recipe = [ < Shell = "cp warn33_input.txt out33.txt" > ], hash = "sha256:0000000000000000000000000000000000000000000000000000000000000000", depsHash = [ { path = "warn33_input.txt", hash = "sha256:1111111111111111111111111111111111111111111111111111111111111111" } ] } } ], default = "out33.txt" }
