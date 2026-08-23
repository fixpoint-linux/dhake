let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action, hash : Text, depsHash : List { path : Text, hash : Text } }
in  { targets = [ { mapKey = "out30.txt", mapValue = { deps = [], phony = False, recipe = [ < Shell = "printf 'hello' > out30.txt" > ], hash = "md5:d41d8cd98f00b204e9800998ecf8427e" } } ], default = "out30.txt" }
