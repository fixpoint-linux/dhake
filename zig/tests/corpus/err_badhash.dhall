let Action = < Shell : Text | Copy : { from : Text, to : Text } | Mkdir : Text | Rm : Text | Touch : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action, hash : Text }
in { targets = [ { mapKey = "x", mapValue = { deps = [] : List Text, phony = True, recipe = [ < Shell = "echo a" > ], hash = "sha256:abcd" } } ], default = "x" }
