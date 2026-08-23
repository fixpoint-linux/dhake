let Action = < Shell : Text | Copy : { from : Text, to : Text } | Mkdir : Text | Rm : Text | Touch : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { targets = [ { mapKey = "a", mapValue = { deps = ["b"], phony = False, recipe = [ < Shell = "touch a" > ] } }, { mapKey = "b", mapValue = { deps = ["a"], phony = False, recipe = [ < Shell = "touch b" > ] } } ], default = "a" }
