let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action, hash : Text, cwd : Text }
in  { targets = [ { mapKey = "sub/empty", mapValue = { deps = [], phony = False, recipe = [ < Shell = "touch empty" > ], hash = "sha256:${HASH_CWD}", cwd = "sub" } } ], default = "sub/empty" }
