let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in  { targets = [ { mapKey = "define_d1", mapValue = { deps = [] : List Text, phony = True, recipe = [ < Shell = "printf '%s' ${env:CC} > cc.txt" > ] } } ], default = "define_d1" }
