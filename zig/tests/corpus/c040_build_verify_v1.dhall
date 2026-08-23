let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action, hash : Text }
in  { targets = [ { mapKey = "verify_v1.txt", mapValue = { deps = [], phony = False, recipe = [ < Shell = "printf 'verify-v1-content' > verify_v1.txt" > ], hash = "sha256:$HASH_V1" } } ], default = "verify_v1.txt" }
