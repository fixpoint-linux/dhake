let Action = < Shell : Text | Copy : { from : Text, to : Text } | Mkdir : Text | Rm : Text | Touch : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { targets = [ { mapKey = "fail", mapValue = { deps = [] : List Text, phony = False, recipe = [ < Shell = "exit 7" > ] } } ], default = "fail" }
