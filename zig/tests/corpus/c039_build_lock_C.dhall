let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in  { targets = [ { mapKey = "lockc", mapValue = { deps = [], phony = False, recipe = [ < Shell = "echo c > lockc" > ] } } ], default = "lockc" }
