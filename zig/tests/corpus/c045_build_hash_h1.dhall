let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action, hash : Text, depsHash : List { path : Text, hash : Text } }
in  { targets = [ { mapKey = "hash_h1.txt", mapValue = { deps = ["src_h1.txt"], phony = False, recipe = [ < Shell = "cp src_h1.txt hash_h1.txt" > ], hash = "sha256:$HASH_H1", depsHash = [ { path = "src_h1.txt", hash = "sha256:$HASH_H1" } ] } } ], default = "hash_h1.txt" }
