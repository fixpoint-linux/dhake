let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action, hash : Text, depsHash : List { path : Text, hash : Text } }
in  { targets = [ { mapKey = "out31.txt", mapValue = { deps = [], phony = False, recipe = [ < Shell = "printf 'hello' > out31.txt" > ], hash = "d41d8cd98f00b204e9800998ecf8427e00000000000000000000000000000000" } } ], default = "out31.txt" }
