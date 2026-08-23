let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action, hash : Text, depsHash : List { path : Text, hash : Text } }
in  { targets = [ { mapKey = "lockoutA.txt", mapValue = { deps = [], phony = False, recipe = [ < Shell = "printf 'lockfile-test' > lockoutA.txt" > ], hash = "sha256:PLACEHOLDER" } } ], default = "lockoutA.txt" }
