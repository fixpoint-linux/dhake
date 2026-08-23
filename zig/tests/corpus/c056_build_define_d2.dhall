let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in  { targets = [ { mapKey = "define_d2", mapValue = { deps = [] : List Text, phony = True, recipe = [ < Shell = "printf '%s' ${env:CC} > cc2.txt" > ] } } ], default = "define_d2" }
