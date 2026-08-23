let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action, hash : Text }
in  { targets = [ { mapKey = "out32.txt", mapValue = { deps = [], phony = False, recipe = [ < Shell = "printf 'hello' > out32.txt" > ], hash = "sha256:0000000000000000000000000000000000000000000000000000000000000000" } } ], default = "out32.txt" }
