let Action = < Shell : Text | Copy : { from : Text, to : Text } | Mkdir : Text | Rm : Text | Touch : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { targets = [ { mapKey = "x", mapValue = { deps = 1, phony = True, recipe = [ < Shell = "echo a" > ] } } ], default = "x" }
