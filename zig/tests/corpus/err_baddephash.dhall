let Action = < Shell : Text | Copy : { from : Text, to : Text } | Mkdir : Text | Rm : Text | Touch : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action, depsHash : List { path : Text, hash : Text } }
in { targets = [ { mapKey = "x", mapValue = { deps = [] : List Text, phony = True, recipe = [ < Shell = "echo a" > ], depsHash = [ "not-a-record" ] } } ], default = "x" }
