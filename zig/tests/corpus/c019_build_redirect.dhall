let Action = < Shell : Text | Copy : { from : Text, to : Text } | Mkdir : Text | Rm : Text | Touch : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { targets = [ { mapKey = "red", mapValue = { deps = [] : List Text, phony = True, recipe = [ < Shell = "echo start; echo x > redirect_target.txt; echo after=$?; echo end" > ] } } ], default = "red" }
