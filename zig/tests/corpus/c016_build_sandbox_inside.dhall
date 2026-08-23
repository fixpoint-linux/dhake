let Action = < Shell : Text | Copy : { from : Text, to : Text } | Mkdir : Text | Rm : Text | Touch : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { sandbox = { enable = True, unveil = [] : List Text }
   , targets = [ { mapKey = "ok", mapValue = { deps = [] : List Text, phony = True, recipe = [ < Shell = "echo hi > sandbox_inside.txt" > ] } } ], default = "ok" }
