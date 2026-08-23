let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action, hash : Text }
in  { targets = [ { mapKey = "verify_v4.txt", mapValue = { deps = [], phony = False, recipe = [ < Shell = "printf 'original-output\\n' > verify_v4.txt" > ], hash = "sha256:$HASH_V4" } } ], default = "verify_v4.txt" }
