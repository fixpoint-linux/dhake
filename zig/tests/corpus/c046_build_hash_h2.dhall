let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action, hash : Text, depsHash : List { path : Text, hash : Text } }
in  { targets = [ { mapKey = "hash_h2.txt", mapValue = { deps = ["src_h2.txt"], phony = False, recipe = [ < Shell = "cp src_h2.txt hash_h2.txt" > ], hash = "sha256:$HASH_H2_OLD", depsHash = [ { path = "src_h2.txt", hash = "sha256:$HASH_H2_OLD" } ] } } ], default = "hash_h2.txt" }
