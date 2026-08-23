let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action, depsHash : List { path : Text, hash : Text } }
in  { targets = [ { mapKey = "verify_v3.txt", mapValue = { deps = ["verify_v3_dep.txt"], phony = False, recipe = [ < Shell = "cp verify_v3_dep.txt verify_v3.txt" > ], depsHash = [ { path = "verify_v3_dep.txt", hash = "sha256:$HASH_V3" } ] } } ], default = "verify_v3.txt" }
